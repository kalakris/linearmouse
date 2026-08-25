// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
import Foundation

/// Drops discrete wheel scroll events from a device whose touch stream is
/// active.
///
/// Streaming firmware also emits standard wheel events as a fallback for
/// driverless hosts; while LinearMouse consumes the raw touch stream, those
/// wheel events would double-fire every scroll. This transformer is appended
/// (first in the chain) only to routes whose scheme both matched the device
/// and enabled `scrolling.touchStream`, so it can never affect other devices.
///
/// Suppression is gated on the stream device being *connected* — not on a
/// gesture being in flight — to avoid edge races around gesture start/end,
/// and turns itself off the moment the stream device disappears so the wheel
/// fallback keeps working when only the pointer interface is present.
///
/// The stream is matched by the pointer device's *physical identity*
/// (`HIDPhysicalDeviceIdentity`), never by vendor/product ID: multiple ZMK
/// keyboards share the default VID/PID, and only the one actually streaming
/// may have its wheel events dropped. When the identity is unknown, nothing
/// is suppressed — a visible double-scroll on the streaming keyboard beats
/// silently killing another keyboard's scrolling.
final class TouchStreamWheelSuppressionTransformer: EventTransformer {
    typealias StreamOpenProvider = (_ identity: HIDPhysicalDeviceIdentity?) -> Bool

    private let deviceIdentity: HIDPhysicalDeviceIdentity?
    private let isStreamOpen: StreamOpenProvider

    init(
        deviceIdentity: HIDPhysicalDeviceIdentity?,
        isStreamOpen: @escaping StreamOpenProvider = {
            TouchStreamManager.shared.isStreamOpen(for: $0)
        }
    ) {
        self.deviceIdentity = deviceIdentity
        self.isStreamOpen = isStreamOpen
    }

    func transform(_ event: CGEvent, in _: EventTransformerContext) -> CGEvent? {
        guard Self.isSuppressibleWheelEvent(
            type: event.type,
            isSynthetic: event.isLinearMouseSyntheticEvent
        ) else {
            return event
        }

        guard isStreamOpen(deviceIdentity) else {
            return event
        }

        return nil
    }

    /// Whether the event is a physical wheel scroll eligible for suppression:
    /// scroll-wheel typed and not one of LinearMouse's own synthetic events
    /// (the touch-stream poster's phased events must always pass through).
    static func isSuppressibleWheelEvent(type: CGEventType, isSynthetic: Bool) -> Bool {
        type == .scrollWheel && !isSynthetic
    }
}
