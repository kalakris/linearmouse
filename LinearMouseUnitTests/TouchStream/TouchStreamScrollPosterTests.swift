// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
@testable import LinearMouse
import XCTest

final class TouchStreamScrollPosterTests: XCTestCase {
    private func scrollWheelEvents(from events: [CGEvent]) -> [ScrollWheelEventView] {
        events.filter { $0.type == .scrollWheel }.map(ScrollWheelEventView.init)
    }

    func testCatchSequencePostsWellFormedPhases() {
        var emittedEvents: [CGEvent] = []
        let poster = TouchStreamScrollPoster(eventSink: { emittedEvents.append($0.copy() ?? $0) })

        // Flick, momentum, then catch and a fresh drag.
        let sequence: [TouchScrollEngine.Event] = [
            .touchBegan,
            .touchChanged(deltaY: 24),
            .touchEnded,
            .momentumBegan(deltaY: 12),
            .momentumChanged(deltaY: 8),
            .momentumEnded,
            .touchBegan,
            .touchChanged(deltaY: -3),
            .touchEnded
        ]
        for event in sequence {
            poster.post(event)
        }

        let views = scrollWheelEvents(from: emittedEvents)
        XCTAssertEqual(views.count, sequence.count)

        let expectedScrollPhases: [CGScrollPhase?] = [
            .began, .changed, .ended, nil, nil, nil, .began, .changed, .ended
        ]
        let expectedMomentumPhases: [CGMomentumScrollPhase] = [
            .none, .none, .none, .begin, .continuous, .end, .none, .none, .none
        ]
        for (index, view) in views.enumerated() {
            XCTAssertEqual(view.scrollPhase, expectedScrollPhases[index], "index \(index)")
            XCTAssertEqual(view.momentumPhase, expectedMomentumPhases[index], "index \(index)")
            XCTAssertTrue(view.continuous)
        }

        XCTAssertEqual(views[1].deltaYFixedPt, 24)
        XCTAssertEqual(views[3].deltaYFixedPt, 12)
        XCTAssertEqual(views[7].deltaYFixedPt, -3)

        // Every scroll event is marked synthetic so LinearMouse's own event
        // tap never re-transforms it.
        XCTAssertTrue(emittedEvents
            .filter { $0.type == .scrollWheel }
            .allSatisfy(\.isLinearMouseSyntheticEvent))

        // Gesture-series companions are emitted alongside touch phases (the
        // non-scrollWheel gesture events).
        XCTAssertGreaterThan(emittedEvents.count, views.count)
    }

    func testSubpixelDeltasAccumulateAcrossTouchChanges() {
        var emittedEvents: [CGEvent] = []
        let poster = TouchStreamScrollPoster(eventSink: { emittedEvents.append($0.copy() ?? $0) })

        poster.post(.touchBegan)
        for _ in 0 ..< 4 {
            poster.post(.touchChanged(deltaY: 0.4))
        }
        poster.post(.touchEnded)

        let views = scrollWheelEvents(from: emittedEvents)
        // Fixed-point delta carries the value (within the field's 16.16
        // fixed-point resolution)...
        XCTAssertEqual(views[1].deltaYFixedPt, 0.4, accuracy: 1e-4)
        // ...while integer point deltas accumulate remainders instead of
        // truncating each fraction to zero.
        let totalPointDelta = views.reduce(0.0) { $0 + $1.deltaYPt }
        XCTAssertEqual(totalPointDelta, 1)
    }
}
