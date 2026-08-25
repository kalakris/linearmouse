// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class ReverseScrollingTransformerTests: XCTestCase {
    func testReverseScrollingVertically() throws {
        let transformer = ReverseScrollingTransformer(vertically: true)
        var event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 1,
            wheel2: 2,
            wheel3: 0
        ))
        event = try XCTUnwrap(transformer.transform(event, in: EventTransformerContext(device: nil)))
        let view = ScrollWheelEventView(event)
        XCTAssertEqual(view.deltaX, 2)
        XCTAssertEqual(view.deltaY, -1)
    }

    func testReverseScrollingHorizontally() throws {
        let transformer = ReverseScrollingTransformer(horizontally: true)
        var event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 1,
            wheel2: 2,
            wheel3: 0
        ))
        event = try XCTUnwrap(transformer.transform(event, in: EventTransformerContext(device: nil)))
        let view = ScrollWheelEventView(event)
        XCTAssertEqual(view.deltaX, -2)
        XCTAssertEqual(view.deltaY, 1)
    }

    /// LinearMouse's own synthetic scroll events (smoothed scrolling,
    /// touch-stream scrolling) re-enter the event tap after being posted.
    /// The reverse decision for them is already applied at the source, so
    /// the transformer must pass them through untouched — otherwise the
    /// user-facing toggle would be applied twice and cancel itself out.
    func testLeavesSyntheticEventsUntouched() throws {
        let transformer = ReverseScrollingTransformer(vertically: true, horizontally: true)
        var event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 3,
            wheel2: 4,
            wheel3: 0
        ))
        event.isLinearMouseSyntheticEvent = true

        event = try XCTUnwrap(transformer.transform(event, in: EventTransformerContext(device: nil)))
        let view = ScrollWheelEventView(event)
        XCTAssertEqual(view.deltaX, 4)
        XCTAssertEqual(view.deltaY, 3)
    }
}
