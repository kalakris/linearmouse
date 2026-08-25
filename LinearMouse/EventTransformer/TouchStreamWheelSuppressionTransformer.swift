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
final class TouchStreamWheelSuppressionTransformer: EventTransformer {
    typealias StreamOpenProvider = (_ vendorID: Int?, _ productID: Int?) -> Bool

    private let vendorID: Int?
    private let productID: Int?
    private let isStreamOpen: StreamOpenProvider

    init(
        vendorID: Int?,
        productID: Int?,
        isStreamOpen: @escaping StreamOpenProvider = {
            TouchStreamManager.shared.isStreamOpen(vendorID: $0, productID: $1)
        }
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.isStreamOpen = isStreamOpen
    }

    func transform(_ event: CGEvent, in _: EventTransformerContext) -> CGEvent? {
        guard Self.isSuppressibleWheelEvent(
            type: event.type,
            isSynthetic: event.isLinearMouseSyntheticEvent
        ) else {
            return event
        }

        guard isStreamOpen(vendorID, productID) else {
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
