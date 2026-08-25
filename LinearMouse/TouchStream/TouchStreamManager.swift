// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Combine
import Foundation
import IOKit.hid
import os.log

/// Consumes the raw touch stream from a supported keyboard trackpad and
/// synthesizes trackpad-style scrolling.
///
/// The device (MoErgo Go60 right half prototype firmware) exposes a
/// vendor-defined HID collection (usage page 0xFF00, usage 0x01) that macOS
/// enumerates as a separate `IOHIDDevice`. Input reports carry absolute Cirque
/// touch frames (see `TouchStreamFrame`).
///
/// Data flow and threading:
/// - An `IOHIDManager` matches the vendor collection (by VID/PID + usage pair)
///   and is scheduled on the main run loop. It survives device
///   connect/disconnect (BLE and USB) — matching/removal is handled by the
///   manager itself — and is a complete no-op while the device is absent.
/// - The input-report callback parses each report into a `TouchStreamFrame`
///   (dropping malformed/short reports) and hops to `EventThread`, where all
///   engine/poster state lives — the same thread `SmoothedScrollingTransformer`
///   uses for synthetic event posting.
/// - `TouchScrollEngine` maps frames to gesture events; during momentum an
///   `EventThreadTimer` at 120 Hz drives the decay. `TouchStreamScrollPoster`
///   turns engine events into phased CGEvents posted to the session event tap.
///
/// Prototype scope: the device is matched by the hardcoded constants below
/// rather than through the scheme device matcher — the touch stream is not a
/// CGEvent source, so per-scheme matching does not naturally apply. The
/// feature is gated by the top-level `touchStream` configuration key.
final class TouchStreamManager {
    static let shared = TouchStreamManager()

    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "TouchStream")
    private static let momentumTimerInterval: TimeInterval = 1.0 / 120.0

    /// Frozen protocol constants for the prototype device.
    private enum Constants {
        static let vendorID = 0x16C0
        static let productID = 0x27D9
        static let usagePage = 0xFF00
        static let usage = 0x01
    }

    // Main-thread state.
    private var started = false
    private var hidManager: IOHIDManager?
    private var subscriptions = Set<AnyCancellable>()

    // Event-thread state. Only ever touched from EventThread blocks.
    private let engine = TouchScrollEngine()
    private let poster = TouchStreamScrollPoster()
    private var momentumTimer: EventThreadTimer?

    private let now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init() {}

    // MARK: - Lifecycle (main thread)

    func start() {
        guard !started else {
            return
        }
        started = true

        ConfigurationState.shared.$configuration
            .map(\.touchStream)
            .removeDuplicates()
            .sink { [weak self] touchStream in
                self?.apply(touchStream: touchStream)
            }
            .store(in: &subscriptions)
    }

    func stop() {
        guard started else {
            return
        }
        started = false

        subscriptions.removeAll()
        closeHIDManager()
        interruptGesture()
    }

    private func apply(touchStream: Configuration.TouchStream?) {
        guard started else {
            return
        }

        guard let touchStream, touchStream.isEnabled else {
            closeHIDManager()
            interruptGesture()
            return
        }

        let config = TouchScrollEngine.Config(
            pointsPerCount: touchStream.resolvedScale,
            invert: touchStream.isInverted,
            axis: touchStream.resolvedAxis
        )
        EventThread.shared.perform { [weak self] in
            self?.engine.config = config
        }

        openHIDManagerIfNeeded()
    }

    // MARK: - IOHIDManager (main thread)

    private func openHIDManagerIfNeeded() {
        guard hidManager == nil else {
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // VID/PID narrows it to the Go60 right half; the usage pair selects
        // the vendor-defined collection among its HID interfaces. The report
        // ID is deliberately not part of the match or the parse.
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
        os_log(
            "Touch stream device connected: %{public}@",
            log: Self.log,
            type: .info,
            IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
        )
    }

    private func deviceDidDisconnect(_: IOHIDDevice) {
        os_log("Touch stream device disconnected", log: Self.log, type: .info)
        // Close out any gesture in flight so apps are not left mid-phase.
        interruptGesture()
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
            momentumTimer?.invalidate()
            momentumTimer = nil
        }
    }
}
