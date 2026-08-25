// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class TouchStreamClickPosterTests: XCTestCase {
    func testTapPostsMarkedDownUpPairWithClickState() {
        var emittedEvents: [CGEvent] = []
        let poster = TouchStreamClickPoster(eventSink: { emittedEvents.append($0.copy() ?? $0) })

        poster.post(.init(clickState: 2, location: .init(x: 10, y: 20)))

        XCTAssertEqual(emittedEvents.map(\.type), [.leftMouseDown, .leftMouseUp])
        for event in emittedEvents {
            XCTAssertEqual(event.location, CGPoint(x: 10, y: 20))
            XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 2)
            // Marked synthetic so LinearMouse's own event tap (e.g. button
            // mappings) never re-transforms the click.
            XCTAssertTrue(event.isLinearMouseSyntheticEvent)
        }
    }

    func testSingleTapCarriesClickStateOne() {
        var emittedEvents: [CGEvent] = []
        let poster = TouchStreamClickPoster(eventSink: { emittedEvents.append($0.copy() ?? $0) })

        poster.post(.init(clickState: 1, location: .zero))

        XCTAssertEqual(emittedEvents.count, 2)
        XCTAssertTrue(emittedEvents.allSatisfy {
            $0.getIntegerValueField(.mouseEventClickState) == 1
        })
    }
}
