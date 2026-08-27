// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Combine
import Foundation
import IOKit.hid
import os.log

/// Consumes the raw touch stream from a supported keyboard trackpad and
/// synthesizes trackpad-style scrolling.
///
/// A supported keyboard (e.g. the MoErgo Go60 right half) exposes a
/// vendor-defined HID collection (usage page 0xFF00, usage 0x01) that macOS
/// enumerates as a separate `IOHIDDevice`. Input reports carry absolute
/// Cirque touch frames (see `TouchStreamFrame`); a feature report describes
/// the device's capabilities and pad orientation (see
/// `TouchStreamCapabilities`).
///
/// Lifecycle:
/// - `start()` opens an `IOHIDManager` matching the vendor collection by the
///   usage pair alone — deliberately not by VID/PID, so any keyboard whose
///   firmware implements the protocol streams, not just one hardcoded model
///   (ZMK keyboards share a default VID/PID anyway, so it could never tell
///   implementors apart) — on the event thread's run loop. It survives
///   device connect/disconnect (BLE and USB) and is a complete no-op while
///   no device is present. `GlobalEventTap` restarts the manager around
///   event-thread restarts so it is never left scheduled on a dead run
///   loop.
/// - On device connect the feature report is read and validated once; this
///   is the hard gate that admits a device as a stream source. A foreign
///   device that merely shares the vendor usage pair fails it and is
///   ignored entirely (logged, non-streaming) — `handleReport` drops input
///   reports from anything that has not passed the gate.
/// - The touch-stream configuration lives on the per-device scheme
///   (`schemes[].scrolling.touchStream`), matched against the keyboard's
///   pointer device. The pointer device is identified by physical identity
///   (`HIDPhysicalDeviceIdentity`) rather than vendor/product ID, because
///   multiple ZMK keyboards can share the same VID/PID. The scroll axis comes
///   from the device's self-reported orientation; the direction baseline
///   follows the macOS Natural Scrolling preference (like wheel devices,
///   which macOS flips upstream of the event tap), and the scheme's generic
///   `scrolling.reverse` (vertical) toggle flips that — all applied here as
///   the engine's output sign (the event-tap reverse transformer skips
///   synthetic events, so no flip happens twice). The Natural Scrolling
///   checkbox is observed via its distributed change notification, so
///   toggling it re-derives the sign live.
///
/// Data flow and threading:
/// - The `IOHIDManager` is scheduled on `EventThread`'s run loop, so the
///   ~100 Hz input-report callback parses each report into a
///   `TouchStreamFrame` (dropping malformed/short reports) directly on the
///   thread where all engine/poster state lives — the same thread
///   `SmoothedScrollingTransformer` uses for synthetic event posting — with
///   no per-frame thread hop. Device connect/disconnect callbacks fire on
///   that thread too and are rare, so they hop to the main thread, where
///   the device list, the published identities, and scheme resolution live.
/// - `TouchScrollEngine` maps frames to gesture events; during momentum an
///   `EventThreadTimer` at 120 Hz drives the decay. `TouchStreamScrollPoster`
///   turns engine events into phased CGEvents posted to the session event tap.
/// - `isStreamOpen(for:)` is thread-safe and is polled by
///   `TouchStreamWheelSuppressionTransformer` on the event-tap thread to drop
///   the firmware's fallback wheel events while the stream is connected. It
///   matches on physical identity, so a second keyboard sharing the same
///   VID/PID never has its wheel events suppressed.
final class TouchStreamManager: ObservableObject {
    static let shared = TouchStreamManager()

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "TouchStream")
    private static let momentumTimerInterval: TimeInterval = 1.0 / 120.0

    /// Frozen protocol constants: the vendor-defined usage pair the touch
    /// stream lives on. Deliberately no VID/PID — the feature-report
    /// validation, not the device's identity, decides who streams.
    private enum Constants {
        static let usagePage = 0xFF00
        static let usage = 0x01
    }

    private struct StreamDevice {
        var device: IOHIDDevice
        var identity: HIDPhysicalDeviceIdentity
        var capabilities: TouchStreamCapabilities
    }

    // Main-thread state.
    private var started = false
    private var hidManager: IOHIDManager?
    /// The run loop `hidManager` is scheduled on (the event thread's, or the
    /// main one as a degenerate fallback when the event thread is down).
    private var hidManagerRunLoop: CFRunLoop?
    private var subscriptions = Set<AnyCancellable>()
    private var streamDevices: [StreamDevice] = []

    /// Physical identities of connected, capability-verified streaming
    /// devices. Main-thread published for the UI ("Raw Touch" mode
    /// availability in the Scrolling settings).
    @Published private(set) var streamingDeviceIdentities: [HIDPhysicalDeviceIdentity] = []

    // Cross-thread mirrors of the verified-device state: the identities for
    // the event-tap (wheel suppression) path, the device handles for the
    // input-report path's validation gate.
    private let streamingDeviceIdentitiesLock = NSLock()
    private var lockedStreamingDeviceIdentities: [HIDPhysicalDeviceIdentity] = []
    private var lockedStreamDeviceHandles: [IOHIDDevice] = []

    /// Reads the system-wide Natural Scrolling preference. Injectable so the
    /// direction derivation stays testable without global state; the default
    /// reads the global preference domain.
    private let systemPrefersNaturalScrolling: () -> Bool

    // Event-thread state. Only ever touched from EventThread blocks.
    private let engine = TouchScrollEngine()
    private let poster = TouchStreamScrollPoster()
    private var scrollingEnabled = false
    private var momentumTimer: EventThreadTimer?

    init(
        systemPrefersNaturalScrolling: @escaping () -> Bool = SystemScrollingPreference.prefersNatural
    ) {
        self.systemPrefersNaturalScrolling = systemPrefersNaturalScrolling
    }

    // MARK: - Cross-thread queries

    /// Whether a capability-verified streaming collection belonging to the
    /// same physical device as `identity` is currently connected. Safe to
    /// call from any thread; used by the wheel-suppression transformer per
    /// event.
    ///
    /// Conservative on unknowns: a `nil` or indeterminate identity yields
    /// `false`, so wheel events are never suppressed for a device we cannot
    /// positively link to an open stream (visible double-scroll is the safe
    /// failure; silently dropping another keyboard's scrolling is not).
    func isStreamOpen(for identity: HIDPhysicalDeviceIdentity?) -> Bool {
        guard let identity else {
            return false
        }

        streamingDeviceIdentitiesLock.lock()
        defer { streamingDeviceIdentitiesLock.unlock() }
        return lockedStreamingDeviceIdentities.contains { $0.isSamePhysicalDevice(as: identity) }
    }

    /// Whether `device` (a pointer device) belongs to the same physical
    /// keyboard as a currently connected streaming collection. Main thread.
    func isStreamingDevice(_ device: Device) -> Bool {
        guard let identity = device.physicalIdentity else {
            return false
        }

        return streamingDeviceIdentities.contains { $0.isSamePhysicalDevice(as: identity) }
    }

    // MARK: - Lifecycle (main thread)

    func start() {
        // Opening the HID manager on a keyboard's vendor collection can hit
        // TCC (Input Monitoring / Accessibility prompts). Never do that from
        // ephemeral test hosts — each `xcodebuild test` run would prompt anew.
        guard ProcessEnvironment.isRunningApp else {
            return
        }

        guard !started else {
            return
        }
        started = true

        Self.configurationChanges(ConfigurationState.shared.$configuration)
            .sink { [weak self] _ in
                self?.reconfigure()
            }
            .store(in: &subscriptions)

        // The pointer device that anchors scheme matching can enumerate after
        // the vendor collection; re-resolve when the device list settles.
        DeviceManager.shared.$devices
            .debounce(for: 0.1, scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.reconfigure()
            }
            .store(in: &subscriptions)

        // The Natural Scrolling checkbox announces changes via a distributed
        // notification; the engine sign depends on it, so re-derive live.
        // Hop to the main queue (the same timing-safe idiom as
        // `configurationChanges`): `reconfigure` runs on the main thread and
        // re-reads the preference fresh, after the write has been committed.
        DistributedNotificationCenter.default()
            .publisher(for: SystemScrollingPreference.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconfigure()
            }
            .store(in: &subscriptions)

        openHIDManagerIfNeeded()
    }

    func stop() {
        guard started else {
            return
        }
        started = false

        subscriptions.removeAll()
        closeHIDManager()
        streamDevices.removeAll()
        updateStreamingDeviceIdentities()
        interruptGesture()
    }

    // MARK: - Configuration (main thread)

    /// Configuration changes, delivered only after the new value is committed.
    ///
    /// `@Published` publishes from `willSet`, so a synchronous sink runs while
    /// `ConfigurationState.shared.configuration` still holds the *previous*
    /// value. `reconfigure()` reads the stored configuration (not the emitted
    /// one), so a synchronous subscription would push an engine config one
    /// change behind — e.g. the reverse-scrolling toggle inverting the
    /// direction one toggle late. Deferring delivery to the next main-queue
    /// turn (the same idiom `Device`'s configuration observer uses) makes the
    /// read see the committed value. Internal for unit testing.
    static func configurationChanges(
        _ configuration: Published<Configuration>.Publisher
    ) -> AnyPublisher<Configuration, Never> {
        configuration
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    /// Recomputes the engine configuration from the connected device's
    /// capabilities and its per-device scheme, and pushes it to the event
    /// thread.
    private func reconfigure() {
        guard started else {
            return
        }

        guard let streamDevice = streamDevices.first else {
            setEventThreadConfiguration(scrolling: nil)
            return
        }

        let scrolling = resolvedScrollingConfiguration(for: streamDevice)
        guard let touchStream = scrolling.$touchStream, touchStream.isEnabled else {
            setEventThreadConfiguration(scrolling: nil)
            return
        }

        let capabilities = streamDevice.capabilities
        let acceleration = touchStream.acceleration ?? .init()
        let momentum = touchStream.momentum ?? .init()
        let config = TouchScrollEngine.Config(
            pointsPerCount: touchStream.resolvedScale,
            invert: capabilities.scrollInverted(
                systemPrefersNatural: systemPrefersNaturalScrolling(),
                reversed: scrolling.$reverse?.vertical ?? false
            ),
            axis: capabilities.scrollAxis,
            acceleration: .init(
                enabled: acceleration.isEnabled,
                exponent: acceleration.resolvedExponent,
                referenceSpeed: acceleration.resolvedReferenceSpeed,
                minGain: acceleration.resolvedMinGain,
                maxGain: acceleration.resolvedMaxGain
            ),
            momentum: .init(
                decayTimeConstant: momentum.resolvedDecayTimeConstant,
                startThreshold: momentum.resolvedStartThreshold,
                maxSpeed: momentum.resolvedMaxSpeed
            )
        )

        setEventThreadConfiguration(scrolling: config)
    }

    /// The merged `scrolling` configuration for the scheme matching the
    /// keyboard's pointer device — the touch-stream tuning plus the generic
    /// `reverse` toggle that decides the effective scroll direction.
    private func resolvedScrollingConfiguration(
        for streamDevice: StreamDevice
    ) -> Scheme.Scrolling {
        let configuration = ConfigurationState.shared.configuration

        // Anchor scheme resolution to the pointer device of the *same
        // physical keyboard* as the vendor collection. VID/PID cannot do
        // this (multiple ZMK keyboards ship the same default VID/PID);
        // physical identity decides.
        if let pointerDevice = DeviceManager.shared.devices.first(where: { device in
            guard let identity = device.physicalIdentity else {
                return false
            }

            return streamDevice.identity.isSamePhysicalDevice(as: identity)
        }) {
            return configuration.matchScheme(
                withDevice: pointerDevice,
                withProcess: nil,
                withDisplay: nil
            ).scrolling
        }

        // The pointer device has not enumerated (yet) or could not be linked
        // by physical identity; fall back to a matcher built from the vendor
        // collection's own HID properties, which share
        // vendor/product/name/serial with the pointer interface.
        let matcher = DeviceMatcher(
            vendorID: IOHIDDeviceGetProperty(
                streamDevice.device,
                kIOHIDVendorIDKey as CFString
            ) as? Int,
            productID: IOHIDDeviceGetProperty(
                streamDevice.device,
                kIOHIDProductIDKey as CFString
            ) as? Int,
            productName: IOHIDDeviceGetProperty(
                streamDevice.device,
                kIOHIDProductKey as CFString
            ) as? String,
            serialNumber: IOHIDDeviceGetProperty(
                streamDevice.device,
                kIOHIDSerialNumberKey as CFString
            ) as? String,
            category: [.mouse]
        )
        return configuration.matchScheme(withDeviceMatcher: matcher).scrolling
    }

    private func setEventThreadConfiguration(scrolling: TouchScrollEngine.Config?) {
        EventThread.shared.perform { [weak self] in
            guard let self else {
                return
            }

            scrollingEnabled = scrolling != nil
            if let scrolling {
                engine.config = scrolling
            } else {
                for event in engine.interrupt() {
                    poster.post(event)
                }
                poster.closeGestureSeriesIfNeeded()
                momentumTimer?.invalidate()
                momentumTimer = nil
            }
        }
    }

    // MARK: - IOHIDManager (main thread)

    private func openHIDManagerIfNeeded() {
        guard hidManager == nil else {
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match on the vendor usage pair alone: any keyboard implementing
        // the touch-stream protocol qualifies, and the feature-report
        // validation in `deviceDidConnect` — not a VID/PID — decides whether
        // a matched device actually streams. The report ID is not part of
        // the match (IOHIDManager cannot match on it); the input-report
        // callback filters on it instead — see `handleReport`.
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Constants.usagePage,
            kIOHIDDeviceUsageKey: Constants.usage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        // Connect/disconnect handling touches main-thread state (the device
        // list, the @Published identities, scheme resolution), so those rare
        // callbacks hop to the main thread. Input reports (~100 Hz) are
        // consumed on the scheduling thread itself — see `handleReport`.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else {
                return
            }
            let manager = Unmanaged<TouchStreamManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.deviceDidConnect(device)
            }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else {
                return
            }
            let manager = Unmanaged<TouchStreamManager>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                manager.deviceDidDisconnect(device)
            }
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, sender, type, reportID, report, reportLength in
            guard let context, let sender, result == kIOReturnSuccess, type == kIOHIDReportTypeInput else {
                return
            }
            let manager = Unmanaged<TouchStreamManager>.fromOpaque(context).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            manager.handleReport(from: device, reportID: reportID, bytes: report, length: reportLength)
        }, context)

        // Schedule on the event thread's run loop so input reports arrive
        // directly on the thread that consumes them — no per-report hop, no
        // main-thread wakeups. The main run loop is a degenerate fallback for
        // the case where the event thread is not running (e.g. accessibility
        // permission missing — no synthetic events can be posted then
        // anyway); `handleReport` handles both.
        let runLoop: CFRunLoop = EventThread.shared.runLoop?.getCFRunLoop() ?? CFRunLoopGetMain()
        hidManagerRunLoop = runLoop
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue)

        // An open failure (e.g. missing input-monitoring approval) leaves the
        // manager harmlessly idle; matching may also simply produce no devices
        // while the keyboard is disconnected.
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            os_log(
                "IOHIDManagerOpen returned 0x%{public}x; touch stream idle until a matching device opens",
                log: Self.log,
                type: .error,
                openResult
            )
        }

        hidManager = manager
    }

    private func closeHIDManager() {
        guard let manager = hidManager else {
            return
        }
        hidManager = nil

        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        if let runLoop = hidManagerRunLoop {
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.commonModes.rawValue)
        }
        hidManagerRunLoop = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func deviceDidConnect(_ device: IOHIDDevice) {
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"

        guard let capabilities = readCapabilities(from: device) else {
            os_log(
                "Device %{public}@ has no supported touch-stream feature report; treating as non-streaming",
                log: Self.log,
                type: .info,
                productName
            )
            return
        }

        os_log(
            """
            Touch stream device connected: %{public}@ (protocol v%{public}d, pads 0x%{public}x, \
            %{public}d counts/mm, rotate90=%{public}d invertX=%{public}d invertY=%{public}d, \
            max %{public}dx%{public}d)
            """,
            log: Self.log,
            type: .info,
            productName,
            capabilities.version,
            capabilities.padsPresent,
            capabilities.countsPerMM,
            capabilities.rotate90 ? 1 : 0,
            capabilities.invertX ? 1 : 0,
            capabilities.invertY ? 1 : 0,
            capabilities.xMax,
            capabilities.yMax
        )

        streamDevices.removeAll { $0.device === device }
        streamDevices.append(.init(
            device: device,
            identity: HIDPhysicalDeviceIdentity(hidDevice: device),
            capabilities: capabilities
        ))
        updateStreamingDeviceIdentities()
        reconfigure()
    }

    private func deviceDidDisconnect(_ device: IOHIDDevice) {
        guard streamDevices.contains(where: { $0.device === device }) else {
            return
        }

        os_log("Touch stream device disconnected", log: Self.log, type: .info)
        streamDevices.removeAll { $0.device === device }
        updateStreamingDeviceIdentities()
        // Close out any gesture in flight so apps are not left mid-phase.
        interruptGesture()
        reconfigure()
    }

    private func updateStreamingDeviceIdentities() {
        let identities = streamDevices.map(\.identity)
        let handles = streamDevices.map(\.device)

        streamingDeviceIdentitiesLock.lock()
        lockedStreamingDeviceIdentities = identities
        lockedStreamDeviceHandles = handles
        streamingDeviceIdentitiesLock.unlock()

        if streamingDeviceIdentities != identities {
            streamingDeviceIdentities = identities
        }
    }

    /// Reads and parses the capability feature report. Returns `nil` when the
    /// report is absent, short, or reports an unsupported protocol version.
    private func readCapabilities(from device: IOHIDDevice) -> TouchStreamCapabilities? {
        var buffer = [UInt8](repeating: 0, count: 64)
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            TouchStreamCapabilities.featureReportID,
            &buffer,
            &length
        )

        guard result == kIOReturnSuccess, length > 0 else {
            return nil
        }

        return TouchStreamCapabilities.parse(reportBytes: Array(buffer[0 ..< length]))
    }

    // MARK: - Report handling

    /// Whether `device` has passed feature-report validation. Thread-safe;
    /// called per input report on the run-loop thread.
    private func isVerifiedStreamDevice(_ device: IOHIDDevice) -> Bool {
        streamingDeviceIdentitiesLock.lock()
        defer { streamingDeviceIdentitiesLock.unlock() }
        return lockedStreamDeviceHandles.contains { $0 === device }
    }

    /// Called by the HID input-report callback on the run loop the manager
    /// is scheduled on — normally the event thread itself.
    private func handleReport(
        from device: IOHIDDevice,
        reportID: UInt32,
        bytes: UnsafeMutablePointer<UInt8>,
        length: CFIndex
    ) {
        // Hard gate: only devices whose feature report passed validation are
        // stream sources. Matching is by usage pair alone, so a foreign
        // vendor collection can deliver reports here — and even the real
        // device's reports must wait until its capabilities are verified.
        guard isVerifiedStreamDevice(device) else {
            return
        }

        // Only touch frames (report ID 0x04) are ours. Depending on transport
        // and collection splitting — over BLE in particular — macOS can
        // deliver *other* input reports of the same HID service to this
        // matched device (e.g. ZMK's 9-byte mouse report), which would parse
        // as a phantom touch frame since `TouchStreamFrame` accepts any
        // payload of sufficient length.
        guard reportID == TouchStreamFrame.reportID else {
            return
        }

        guard length > 0 else {
            return
        }

        var payload = [UInt8](UnsafeBufferPointer(start: bytes, count: length))

        // Defensive: some transports have been observed to prepend the report
        // ID byte. If the payload is one byte longer than the contract, drop
        // the leading byte.
        if payload.count == TouchStreamFrame.payloadLength + 1 {
            payload.removeFirst()
        }

        guard let frame = TouchStreamFrame(
            reportBytes: payload,
            timestamp: ProcessInfo.processInfo.systemUptime
        ) else {
            // Malformed/short report: drop silently (never crash).
            return
        }

        if EventThread.shared.isCurrent {
            process(frame: frame)
        } else {
            // Degenerate fallback scheduling only (see
            // `openHIDManagerIfNeeded`).
            EventThread.shared.perform { [weak self] in
                self?.process(frame: frame)
            }
        }
    }

    // MARK: - Event-thread processing

    private func process(frame: TouchStreamFrame) {
        guard scrollingEnabled else {
            return
        }

        for event in engine.handle(frame: frame) {
            poster.post(event)
        }

        updateMomentumTimer()
    }

    private func updateMomentumTimer() {
        if engine.wantsMomentumTicks {
            guard momentumTimer == nil else {
                return
            }
            momentumTimer = EventThread.shared.scheduleTimer(
                interval: Self.momentumTimerInterval,
                repeats: true
            ) { [weak self] in
                self?.momentumTick()
            }
        } else {
            momentumTimer?.invalidate()
            momentumTimer = nil
        }
    }

    private func momentumTick() {
        for event in engine.momentumTick(at: ProcessInfo.processInfo.systemUptime) {
            poster.post(event)
        }

        if !engine.wantsMomentumTicks {
            momentumTimer?.invalidate()
            momentumTimer = nil
        }
    }

    private func interruptGesture() {
        EventThread.shared.perform { [weak self] in
            guard let self else {
                return
            }

            for event in engine.interrupt() {
                poster.post(event)
            }
            poster.closeGestureSeriesIfNeeded()
            momentumTimer?.invalidate()
            momentumTimer = nil
        }
    }
}
