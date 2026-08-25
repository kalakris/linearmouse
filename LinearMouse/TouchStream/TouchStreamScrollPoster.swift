// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
import Foundation
import GestureKit
import os.log

/// Posts `TouchScrollEngine.Event`s as phased continuous scroll events,
/// mirroring the delivery machinery of `SmoothedScrollingTransformer`
/// (which stays untouched): pixel-unit scroll wheel events with
/// scroll/momentum phase fields, companion gesture events so apps treat the
/// stream as a real trackpad gesture series, the `isLinearMouseSyntheticEvent`
/// marker, and subpixel point-delta accumulation.
///
/// Must only be used from the event thread (the engine's owner already runs
/// there).
final class TouchStreamScrollPoster {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier!, category: "TouchStreamScroll"
    )
    private static let outputLineStepInPoints = 12.0

    private let eventSink: (CGEvent) -> Void

    private var pointDeltaAccumulator = SmoothedScrollPointDeltaAccumulator()
    private var gestureScrollSeriesActive = false

    init(eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        self.eventSink = eventSink
    }

    func post(_ engineEvent: TouchScrollEngine.Event) {
        let scrollPhase: CGScrollPhase?
        let momentumPhase: CGMomentumScrollPhase
        let deltaY: Double
        let accumulatesSubpixelDelta: Bool

        switch engineEvent {
        case .touchBegan:
            pointDeltaAccumulator.reset()
            (scrollPhase, momentumPhase, deltaY, accumulatesSubpixelDelta) = (.began, .none, 0, true)
        case let .touchChanged(delta):
            (scrollPhase, momentumPhase, deltaY, accumulatesSubpixelDelta) = (.changed, .none, delta, true)
        case .touchEnded:
            (scrollPhase, momentumPhase, deltaY, accumulatesSubpixelDelta) = (.ended, .none, 0, true)
        case let .momentumBegan(delta):
            (scrollPhase, momentumPhase, deltaY, accumulatesSubpixelDelta) = (nil, .begin, delta, false)
        case let .momentumChanged(delta):
            (scrollPhase, momentumPhase, deltaY, accumulatesSubpixelDelta) = (nil, .continuous, delta, false)
        case .momentumEnded:
            (scrollPhase, momentumPhase, deltaY, accumulatesSubpixelDelta) = (nil, .end, 0, false)
        }

        guard
            let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: 0,
                wheel2: 0,
                wheel3: 0
            )
        else {
            return
        }

        let flags = ModifierState.normalize(ModifierState.shared.currentFlags)

        let view = ScrollWheelEventView(event)
        view.continuous = true
        view.scrollPhase = scrollPhase
        view.momentumPhase = momentumPhase

        let pointDelta = pointDeltaAccumulator.verticalPointDelta(
            for: deltaY,
            accumulates: accumulatesSubpixelDelta
        )
        view.deltaY = Int64((deltaY / Self.outputLineStepInPoints).rounded(.towardZero))
        view.deltaYPt = pointDelta
        view.deltaYFixedPt = deltaY
        view.ioHidScrollY = deltaY

        event.flags = flags
        event.isLinearMouseSyntheticEvent = true

        postGestureScrollCompanionsIfNeeded(scrollPhase: scrollPhase, deltaY: deltaY, flags: flags)
        eventSink(event)

        if engineEvent == .momentumEnded {
            pointDeltaAccumulator.reset()
        }

        os_log(
            "post touch-stream scroll deltaY=%{public}.3f phase=%{public}@ momentum=%{public}@",
            log: Self.log,
            type: .info,
            deltaY,
            String(describing: scrollPhase),
            String(describing: momentumPhase)
        )
    }

    /// Cleanly closes an open synthetic gesture series (e.g. on teardown when
    /// the engine was interrupted).
    func closeGestureSeriesIfNeeded(flags: CGEventFlags = []) {
        guard gestureScrollSeriesActive else {
            return
        }

        GestureEvent(
            scrollSource: nil,
            phase: .cancelled,
            deltaX: 0,
            deltaY: 0,
            flags: flags
        )?.send(to: eventSink)
        GestureEvent(
            scrollSeriesSource: nil,
            started: false,
            flags: flags
        )?.send(to: eventSink)
        gestureScrollSeriesActive = false
    }

    private func postGestureScrollCompanionsIfNeeded(
        scrollPhase: CGScrollPhase?,
        deltaY: Double,
        flags: CGEventFlags
    ) {
        guard let scrollPhase, let gesturePhase = Self.gesturePhase(for: scrollPhase) else {
            return
        }

        if scrollPhase == .began, !gestureScrollSeriesActive {
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
            gestureScrollSeriesActive = true
        }

        GestureEvent(
            scrollSource: nil,
            phase: gesturePhase,
            deltaX: 0,
            deltaY: deltaY,
            flags: flags
        )?.send(to: eventSink)

        if scrollPhase == .ended || scrollPhase == .cancelled {
            GestureEvent(
                scrollSeriesSource: nil,
                started: false,
                flags: flags
            )?.send(to: eventSink)
            gestureScrollSeriesActive = false
        }
    }

    private static func gesturePhase(for scrollPhase: CGScrollPhase) -> CGSGesturePhase? {
        guard let rawValue = UInt8(exactly: scrollPhase.rawValue) else {
            return nil
        }
        return CGSGesturePhase(rawValue: rawValue)
    }
}
