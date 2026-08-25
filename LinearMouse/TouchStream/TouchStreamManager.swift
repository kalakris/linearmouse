// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Combine
import Foundation
import IOKit.hid
import os.log

/// Consumes the raw touch stream from a supported keyboard trackpad and
/// synthesizes trackpad-style scrolling.
///
/// The device (MoErgo Go60 right half) exposes a vendor-defined HID
/// collection (usage page 0xFF00, usage 0x01) that macOS enumerates as a
/// separate `IOHIDDevice`. Input reports carry absolute Cirque touch frames
/// (see `TouchStreamFrame`); a feature report describes the device's
/// capabilities and pad orientation (see `TouchStreamCapabilities`).
///
/// Lifecycle:
/// - `start()` opens an `IOHIDManager` matching the vendor collection (by
///   VID/PID + usage pair) on the main run loop. It survives device
///   connect/disconnect (BLE and USB) and is a complete no-op while the
///   device is absent.
/// - On device connect the feature report is read once. Devices without a
///   supported feature report are ignored entirely (non-streaming).
/// - The touch-stream configuration lives on the per-device scheme
///   (`schemes[].scrolling.touchStream`), matched against the keyboard's
///   pointer device (same vendor/product ID as the vendor collection). The
///   scroll axis and default direction come from the device's self-reported
///   orientation; the scheme only carries a natural/inverted override.
///
/// Data flow and threading:
/// - The input-report callback parses each report into a `TouchStreamFrame`
///   (dropping malformed/short reports) and hops to `EventThread`, where all
///   engine/poster state lives — the same thread `SmoothedScrollingTransformer`
///   uses for synthetic event posting.
/// - `TouchScrollEngine` maps frames to gesture events; during momentum an
///   `EventThreadTimer` at 120 Hz drives the decay. `TouchStreamScrollPoster`
///   turns engine events into phased CGEvents posted to the session event tap.
/// - `isStreamOpen(vendorID:productID:)` is thread-safe and is polled by
///   `TouchStreamWheelSuppressionTransformer` on the event-tap thread to drop
///   the firmware's fallback wheel events while the stream is connected.
final class TouchStreamManager: ObservableObject {
    static let shared = TouchStreamManager()

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "TouchStream")
    private static let momentumTimerInterval: TimeInterval = 1.0 / 120.0

    /// Frozen protocol constants for the supported device.
    private enum Constants {
        static let vendorID = 0x16C0
        static let productID = 0x27D9
        static let usagePage = 0xFF00
        static let usage = 0x01
    }

    /// Identity of a streaming device, shared with the pointer device of the
    /// same keyboard (the vendor collection and the pointer interface carry
    /// the same vendor/product ID).
    struct StreamDeviceID: Hashable {
        var vendorID: Int
        var productID: Int
    }

    private struct StreamDevice {
        var device: IOHIDDevice
        var id: StreamDeviceID
        var capabilities: TouchStreamCapabilities
    }

    // Main-thread state.
    private var started = false
    private var hidManager: IOHIDManager?
    private var subscriptions = Set<AnyCancellable>()
    private var streamDevices: [StreamDevice] = []

    /// Vendor/product IDs of connected, capability-verified streaming
    /// devices. Main-thread published for the UI ("Raw Touch" mode
    /// availability in the Scrolling settings).
    @Published private(set) var streamingDeviceIDs: Set<StreamDeviceID> = []

    // Cross-thread mirror of `streamingDeviceIDs` for the event-tap path.
    private let streamingDeviceIDsLock = NSLock()
    private var lockedStreamingDeviceIDs: Set<StreamDeviceID> = []

    // Event-thread state. Only ever touched from EventThread blocks.
    private let engine = TouchScrollEngine()
    private let poster = TouchStreamScrollPoster()
    private let tapRecognizer = TouchTapRecognizer()
    private let clickPoster = TouchStreamClickPoster()
    private var scrollingEnabled = false
    private var tapToClickEnabled = false
    private var momentumTimer: EventThreadTimer?

    private let now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init() {}

    // MARK: - Cross-thread queries

    /// Whether a capability-verified streaming device with the given
    /// vendor/product ID is currently connected. Safe to call from any
    /// thread; used by the wheel-suppression transformer per event.
    func isStreamOpen(vendorID: Int?, productID: Int?) -> Bool {
        guard let vendorID, let productID else {
            return false
        }

        streamingDeviceIDsLock.lock()
        defer { streamingDeviceIDsLock.unlock() }
        return lockedStreamingDeviceIDs.contains(.init(vendorID: vendorID, productID: productID))
    }

    /// Whether `device` (a pointer device) belongs to a keyboard whose
    /// streaming collection is currently connected. Main thread.
    func isStreamingDevice(_ device: Device) -> Bool {
        guard let vendorID = device.vendorID, let productID = device.productID else {
            return false
        }

        return streamingDeviceIDs.contains(.init(vendorID: vendorID, productID: productID))
    }

    // MARK: - Lifecycle (main thread)

    func start() {
        guard !started else {
            return
        }
        started = true

        ConfigurationState.shared.$configuration
            .removeDuplicates()
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
        updateStreamingDeviceIDs()
        interruptGesture()
    }

    // MARK: - Configuration (main thread)

    /// Recomputes the engine configuration from the connected device's
    /// capabilities and its per-device scheme, and pushes it to the event
    /// thread.
    private func reconfigure() {
        guard started else {
            return
        }

        guard let streamDevice = streamDevices.first,
              let touchStream = resolvedTouchStreamConfiguration(for: streamDevice),
              touchStream.isEnabled else {
            setEventThreadConfiguration(scrolling: nil, tapToClick: nil)
            return
        }

        let capabilities = streamDevice.capabilities
        let acceleration = touchStream.acceleration ?? .init()
        let momentum = touchStream.momentum ?? .init()
        let config = TouchScrollEngine.Config(
            pointsPerCount: touchStream.resolvedScale,
            invert: capabilities.scrollInverted(for: touchStream.resolvedDirection),
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

        // DEPRECATED: firmware now owns tap-to-click; this stays for older
        // firmware and defaults to off.
        let tapToClick = touchStream.tapToClick ?? .init()
        let tapConfig: TouchTapRecognizer.Config? = touchStream.isTapToClickEnabled
            ? .init(
                maxDuration: tapToClick.resolvedMaxDuration,
                maxMovementCounts: tapToClick.resolvedMaxMovement
            )
            : nil

        setEventThreadConfiguration(scrolling: config, tapToClick: tapConfig)
    }

    /// The merged `scrolling.touchStream` configuration for the scheme
    /// matching the keyboard's pointer device. Returns `nil` when no scheme
    /// configures the touch stream.
    private func resolvedTouchStreamConfiguration(
        for streamDevice: StreamDevice
    ) -> Scheme.Scrolling.TouchStream? {
        let configuration = ConfigurationState.shared.configuration

        if let pointerDevice = DeviceManager.shared.devices.first(where: {
            $0.vendorID == streamDevice.id.vendorID && $0.productID == streamDevice.id.productID
        }) {
            return configuration.matchScheme(
                withDevice: pointerDevice,
                withProcess: nil,
                withDisplay: nil
            ).scrolling.$touchStream
        }

        // The pointer device has not enumerated (yet); fall back to a matcher
        // built from the vendor collection's own HID properties, which share
        // vendor/product/name/serial with the pointer interface.
        let matcher = DeviceMatcher(
            vendorID: streamDevice.id.vendorID,
            productID: streamDevice.id.productID,
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
        return configuration.matchScheme(withDeviceMatcher: matcher).scrolling.$touchStream
    }

    private func setEventThreadConfiguration(
        scrolling: TouchScrollEngine.Config?,
        tapToClick: TouchTapRecognizer.Config?
    ) {
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

            tapToClickEnabled = tapToClick != nil
            if let tapToClick {
                tapRecognizer.config = tapToClick
            } else {
                tapRecognizer.reset()
            }
        }
    }

    // MARK: - IOHIDManager (main thread)

    private func openHIDManagerIfNeeded() {
        guard hidManager == nil else {
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // VID/PID narrows it to the Go60 right half; the usage pair selects
        // the vendor-defined collection among its HID interfaces. The report
        // ID is deliberately not part of the match or the input-report parse.
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Constants.vendorID,
            kIOHIDProductIDKey: Constants.productID,
            kIOHIDDeviceUsagePageKey: Constants.usagePage,
            kIOHIDDeviceUsageKey: Constants.usage
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else {
                return
            }
            let manager = Unmanaged<TouchStreamManager>.fromOpaque(context).takeUnretainedValue()
            manager.deviceDidConnect(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else {
                return
            }
            let manager = Unmanaged<TouchStreamManager>.fromOpaque(context).takeUnretainedValue()
            manager.deviceDidDisconnect(device)
        }, context)
        IOHIDManagerRegisterInputReportCallback(manager, { context, result, _, type, _, report, reportLength in
            guard let context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput else {
                return
            }
            let manager = Unmanaged<TouchStreamManager>.fromOpaque(context).takeUnretainedValue()
            manager.handleReport(bytes: report, length: reportLength)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

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
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
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

        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int
            ?? Constants.vendorID
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int
            ?? Constants.productID

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
            id: .init(vendorID: vendorID, productID: productID),
            capabilities: capabilities
        ))
        updateStreamingDeviceIDs()
        reconfigure()
    }

    private func deviceDidDisconnect(_ device: IOHIDDevice) {
        guard streamDevices.contains(where: { $0.device === device }) else {
            return
        }

        os_log("Touch stream device disconnected", log: Self.log, type: .info)
        streamDevices.removeAll { $0.device === device }
        updateStreamingDeviceIDs()
        // Close out any gesture in flight so apps are not left mid-phase.
        interruptGesture()
        reconfigure()
    }

    private func updateStreamingDeviceIDs() {
        let ids = Set(streamDevices.map(\.id))

        streamingDeviceIDsLock.lock()
        lockedStreamingDeviceIDs = ids
        streamingDeviceIDsLock.unlock()

        if streamingDeviceIDs != ids {
            streamingDeviceIDs = ids
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

    /// Called on the main run loop by the HID input-report callback.
    private func handleReport(bytes: UnsafeMutablePointer<UInt8>, length: CFIndex) {
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

        guard let frame = TouchStreamFrame(reportBytes: payload, timestamp: now()) else {
            // Malformed/short report: drop silently (never crash).
            return
        }

        EventThread.shared.perform { [weak self] in
            self?.process(frame: frame)
        }
    }

    // MARK: - Event-thread processing

    private func process(frame: TouchStreamFrame) {
        guard scrollingEnabled || tapToClickEnabled else {
            return
        }

        if scrollingEnabled {
            for event in engine.handle(frame: frame) {
                poster.post(event)
            }
        }

        // Tap-to-click watches the same frame stream but is entirely
        // independent of the scroll engine: it recognizes pointer-context
        // touches, which the engine ignores, and vice versa.
        if tapToClickEnabled, let tap = tapRecognizer.handle(frame: frame) {
            clickPoster.post(tap)
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
        for event in engine.momentumTick(at: now()) {
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
            tapRecognizer.reset()
            momentumTimer?.invalidate()
            momentumTimer = nil
        }
    }
}
