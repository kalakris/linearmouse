// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
@testable import LinearMouse
import XCTest

final class TouchStreamWheelSuppressionTransformerTests: XCTestCase {
    private let context = EventTransformerContext(device: nil)

    private func makeScrollEvent(synthetic: Bool = false) -> CGEvent {
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: -1,
            wheel2: 0,
            wheel3: 0
        )!
        event.isLinearMouseSyntheticEvent = synthetic
        return event
    }

    func testDropsWheelEventsWhileStreamIsOpen() {
        var queried: [(Int?, Int?)] = []
        let transformer = TouchStreamWheelSuppressionTransformer(
            vendorID: 0x16C0,
            productID: 0x27D9
        ) { vendorID, productID in
            queried.append((vendorID, productID))
            return true
        }

        XCTAssertNil(transformer.transform(makeScrollEvent(), in: context))
        XCTAssertEqual(queried.count, 1)
        XCTAssertEqual(queried.first?.0, 0x16C0)
        XCTAssertEqual(queried.first?.1, 0x27D9)
    }

    func testPassesWheelEventsWhileStreamIsClosed() {
        let transformer = TouchStreamWheelSuppressionTransformer(
            vendorID: 0x16C0,
            productID: 0x27D9
        ) { _, _ in false }

        XCTAssertNotNil(transformer.transform(makeScrollEvent(), in: context))
    }

    func testNeverDropsSyntheticEvents() {
        // The touch-stream poster's own phased scroll events must always pass
        // through, even while the stream is open.
        let transformer = TouchStreamWheelSuppressionTransformer(
            vendorID: 0x16C0,
            productID: 0x27D9
        ) { _, _ in true }

        XCTAssertNotNil(transformer.transform(makeScrollEvent(synthetic: true), in: context))
    }

    func testIgnoresNonScrollEvents() {
        let transformer = TouchStreamWheelSuppressionTransformer(
            vendorID: 0x16C0,
            productID: 0x27D9
        ) { _, _ in true }

        let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        )!
        XCTAssertNotNil(transformer.transform(moveEvent, in: context))
    }

    func testSuppressionGate() {
        XCTAssertTrue(
            TouchStreamWheelSuppressionTransformer.isSuppressibleWheelEvent(
                type: .scrollWheel,
                isSynthetic: false
            )
        )
        XCTAssertFalse(
            TouchStreamWheelSuppressionTransformer.isSuppressibleWheelEvent(
                type: .scrollWheel,
                isSynthetic: true
            )
        )
        XCTAssertFalse(
            TouchStreamWheelSuppressionTransformer.isSuppressibleWheelEvent(
                type: .mouseMoved,
                isSynthetic: false
            )
        )
    }
}
