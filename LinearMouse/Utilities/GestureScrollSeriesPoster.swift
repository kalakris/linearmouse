// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
import Foundation
import GestureKit

/// Emits the companion gesture events that make a synthetic phased scroll
/// stream look like a real trackpad gesture series to apps: a
/// mayBegin + series-start pair before the first `began` scroll gesture, a
/// scroll gesture per phased event, and a series-end after `ended`/
/// `cancelled` — tracking whether a series is currently open so interrupted
/// gestures can be closed out cleanly.
///
/// Shared by `SmoothedScrollingTransformer` and `TouchStreamScrollPoster`;
/// the ordering of emitted events is part of the contract and is pinned by
/// both consumers' tests.
final class GestureScrollSeriesPoster {
    private let eventSink: (CGEvent) -> Void

    /// Whether a gesture scroll series is currently open.
    private(set) var seriesActive = false

    init(eventSink: @escaping (CGEvent) -> Void) {
        self.eventSink = eventSink
    }

    /// Posts the gesture companions for one phased scroll event. Events
    /// without a scroll phase (momentum) have no gesture companions.
    func postCompanionsIfNeeded(
        scrollPhase: CGScrollPhase?,
        deltaX: Double,
        deltaY: Double,
        flags: CGEventFlags
    ) {
        guard let scrollPhase, let gesturePhase = CGSGesturePhase(scrollPhase: scrollPhase) else {
            return
        }

        if scrollPhase == .began, !seriesActive {
            GestureEvent(
                scrollSource: nil,
                phase: .mayBegin,
                deltaX: 0,
                deltaY: 0,
                flags: flags
            )?.send(to: eventSink)
            GestureEvent(
                scrollSeriesSource: nil,
                started: true,
                flags: flags
            )?.send(to: eventSink)
            seriesActive = true
        }

        GestureEvent(
            scrollSource: nil,
            phase: gesturePhase,
            deltaX: deltaX,
            deltaY: deltaY,
            flags: flags
        )?.send(to: eventSink)

        if scrollPhase == .ended || scrollPhase == .cancelled {
            GestureEvent(
                scrollSeriesSource: nil,
                started: false,
                flags: flags
            )?.send(to: eventSink)
            seriesActive = false
        }
    }

    /// Cleanly closes an open gesture series (e.g. on teardown when a
    /// gesture was interrupted).
    func endSeriesIfNeeded(phase: CGSGesturePhase = .cancelled, flags: CGEventFlags) {
        guard seriesActive else {
            return
        }

        GestureEvent(
            scrollSource: nil,
            phase: phase,
            deltaX: 0,
            deltaY: 0,
            flags: flags
        )?.send(to: eventSink)
        GestureEvent(
            scrollSeriesSource: nil,
            started: false,
            flags: flags
        )?.send(to: eventSink)
        seriesActive = false
    }
}

extension CGSGesturePhase {
    init?(scrollPhase: CGScrollPhase) {
        guard let rawValue = UInt8(exactly: scrollPhase.rawValue) else {
            return nil
        }
        self.init(rawValue: rawValue)
    }
}
