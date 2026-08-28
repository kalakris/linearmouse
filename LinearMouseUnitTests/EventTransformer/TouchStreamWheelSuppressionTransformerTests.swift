// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
@testable import LinearMouse
import XCTest

final class TouchStreamWheelSuppressionTransformerTests: XCTestCase {
    private let context = EventTransformerContext(device: nil)
    private let identity = HIDPhysicalDeviceIdentity(registryID: 0x1234, locationID: 0x1420_0000)

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
        var queried: [HIDPhysicalDeviceIdentity?] = []
        let transformer = TouchStreamWheelSuppressionTransformer(
            deviceIdentity: identity
        ) { identity in
            queried.append(identity)
            return true
        }

        XCTAssertNil(transformer.transform(makeScrollEvent(), in: context))
        XCTAssertEqual(queried.count, 1)
        XCTAssertEqual(queried.first, identity)
    }

    func testPassesWheelEventsWhileStreamIsClosed() {
        let transformer = TouchStreamWheelSuppressionTransformer(
            deviceIdentity: identity
        ) { _ in false }

        XCTAssertNotNil(transformer.transform(makeScrollEvent(), in: context))
    }

    func testForwardsUnknownIdentityToProvider() {
        // The transformer itself stays a pass-through pipe: the conservative
        // "unknown identity never suppresses" decision lives in
        // `TouchStreamManager.isStreamOpen(for:)`, which receives the nil.
        var queried: [HIDPhysicalDeviceIdentity?] = []
        let transformer = TouchStreamWheelSuppressionTransformer(
            deviceIdentity: nil
        ) { identity in
            queried.append(identity)
            return false
        }

        XCTAssertNotNil(transformer.transform(makeScrollEvent(), in: context))
        XCTAssertEqual(queried, [nil])
    }

    func testNeverDropsSyntheticEvents() {
        // The touch-stream poster's own phased scroll events must always pass
        // through, even while the stream is open.
        let transformer = TouchStreamWheelSuppressionTransformer(
            deviceIdentity: identity
        ) { _ in true }

        XCTAssertNotNil(transformer.transform(makeScrollEvent(synthetic: true), in: context))
    }

    func testIgnoresNonScrollEvents() throws {
        let transformer = TouchStreamWheelSuppressionTransformer(
            deviceIdentity: identity
        ) { _ in true }

        let moveEvent = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left
        ))
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
