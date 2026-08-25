// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class TouchTapRecognizerTests: XCTestCase {
    private static let frameInterval: TimeInterval = 0.01 // ~100 Hz device cadence

    /// Injected system state: tests move the cursor between taps to exercise
    /// the multi-click chain rules.
    private var cursorLocation: CGPoint? = .init(x: 100, y: 100)
    private var doubleClickInterval: TimeInterval = 0.5

    private func makeRecognizer(
        maxDuration: TimeInterval = 0.18,
        maxMovementCounts: Double = 30
    ) -> TouchTapRecognizer {
        TouchTapRecognizer(
            config: .init(maxDuration: maxDuration, maxMovementCounts: maxMovementCounts),
            doubleClickInterval: { [weak self] in self?.doubleClickInterval ?? 0.5 },
            cursorLocation: { [weak self] in self?.cursorLocation }
        )
    }

    private func pointerFrame(
        x: Int = 1000,
        y: Int = 500,
        at timestamp: TimeInterval,
        pad: UInt8 = 0
    ) -> TouchStreamFrame {
        .init(padID: pad, x: x, y: y, z: 40, touched: true, scrollMode: false, timestamp: timestamp)
    }

    private func scrollFrame(x: Int = 1000, y: Int = 500, at timestamp: TimeInterval) -> TouchStreamFrame {
        .init(x: x, y: y, z: 40, touched: true, scrollMode: true, timestamp: timestamp)
    }

    private func releaseFrame(at timestamp: TimeInterval, scrollMode: Bool = false) -> TouchStreamFrame {
        .init(touched: false, scrollMode: scrollMode, timestamp: timestamp)
    }

    /// Feeds a whole touch-down → lift-off sequence of pointer-context frames
    /// and returns the tap recognized at lift-off, if any.
    @discardableResult
    private func performTap(
        on recognizer: TouchTapRecognizer,
        startingAt startTime: TimeInterval = 0,
        frames: Int = 5,
        countsPerFrame: Int = 0
    ) -> TouchTapRecognizer.Tap? {
        var timestamp = startTime
        var x = 1000

        for step in 0 ..< frames {
            timestamp = startTime + Double(step) * Self.frameInterval
            XCTAssertNil(recognizer.handle(frame: pointerFrame(x: x, at: timestamp)))
            x += countsPerFrame
        }

        timestamp += Self.frameInterval
        return recognizer.handle(frame: releaseFrame(at: timestamp))
    }

    // MARK: - Qualifying taps

    func testQuickStationaryTapClicks() {
        let recognizer = makeRecognizer()
        let tap = performTap(on: recognizer)

        XCTAssertEqual(tap, .init(clickState: 1, location: .init(x: 100, y: 100)))
    }

    func testTapWithSmallMovementStillClicks() {
        let recognizer = makeRecognizer()
        // 5 counts per frame over 4 steps = 20 counts total, under the limit.
        let tap = performTap(on: recognizer, countsPerFrame: 5)

        XCTAssertEqual(tap?.clickState, 1)
    }

    // MARK: - Disqualified touches

    func testLongHoldDoesNotClick() {
        let recognizer = makeRecognizer()
        // 30 frames at 100 Hz ≈ 300 ms, past the 180 ms limit.
        let tap = performTap(on: recognizer, frames: 30)

        XCTAssertNil(tap)
    }

    func testTooMuchMovementDoesNotClick() {
        let recognizer = makeRecognizer()
        // 15 counts per frame over 4 steps = 60 counts total, over the limit —
        // even though the touch itself is short.
        let tap = performTap(on: recognizer, countsPerFrame: 15)

        XCTAssertNil(tap)
    }

    func testMovementOnYAxisAloneDisqualifies() {
        let recognizer = makeRecognizer()
        XCTAssertNil(recognizer.handle(frame: pointerFrame(y: 500, at: 0)))
        XCTAssertNil(recognizer.handle(frame: pointerFrame(y: 560, at: Self.frameInterval)))
        // Returning near the start does not forgive the excursion.
        XCTAssertNil(recognizer.handle(frame: pointerFrame(y: 505, at: Self.frameInterval * 2)))

        XCTAssertNil(recognizer.handle(frame: releaseFrame(at: Self.frameInterval * 3)))
    }

    func testSequenceContainingScrollModeFramesNeverClicks() {
        let recognizer = makeRecognizer()

        // The momentum-catch gesture: a brief scroll-mode touch to stop a
        // coasting scroll. Short and stationary, but it must never click.
        XCTAssertNil(recognizer.handle(frame: scrollFrame(at: 0)))
        XCTAssertNil(recognizer.handle(frame: scrollFrame(at: Self.frameInterval)))
        XCTAssertNil(recognizer.handle(frame: releaseFrame(at: Self.frameInterval * 2)))

        // Even a single scroll-mode frame in an otherwise pointer-context
        // touch disqualifies the whole sequence.
        XCTAssertNil(recognizer.handle(frame: pointerFrame(at: 1.0)))
        XCTAssertNil(recognizer.handle(frame: scrollFrame(at: 1.0 + Self.frameInterval)))
        XCTAssertNil(recognizer.handle(frame: pointerFrame(at: 1.0 + Self.frameInterval * 2)))
        XCTAssertNil(recognizer.handle(frame: releaseFrame(at: 1.0 + Self.frameInterval * 3)))
    }

    func testScrollModeOnReleaseFrameDisqualifies() {
        let recognizer = makeRecognizer()
        XCTAssertNil(recognizer.handle(frame: pointerFrame(at: 0)))
        XCTAssertNil(recognizer.handle(frame: releaseFrame(at: Self.frameInterval, scrollMode: true)))
    }

    func testLeftPadFramesAreIgnored() {
        let recognizer = makeRecognizer()
        XCTAssertNil(recognizer.handle(frame: pointerFrame(at: 0, pad: 1)))
        XCTAssertNil(recognizer.handle(
            frame: .init(padID: 1, touched: false, scrollMode: false, timestamp: Self.frameInterval)
        ))
    }

    func testStrayReleaseWithoutTouchDoesNothing() {
        let recognizer = makeRecognizer()
        XCTAssertNil(recognizer.handle(frame: releaseFrame(at: 0)))
    }

    func testResetDropsTouchInProgress() {
        let recognizer = makeRecognizer()
        XCTAssertNil(recognizer.handle(frame: pointerFrame(at: 0)))
        recognizer.reset()
        XCTAssertNil(recognizer.handle(frame: releaseFrame(at: Self.frameInterval)))
    }

    // MARK: - Multi-click chains

    func testDoubleTapProducesClickStateTwo() {
        let recognizer = makeRecognizer()

        XCTAssertEqual(performTap(on: recognizer, startingAt: 0)?.clickState, 1)
        XCTAssertEqual(performTap(on: recognizer, startingAt: 0.2)?.clickState, 2)
    }

    func testTripleTapProducesClickStateThreeThenWrapsToOne() {
        let recognizer = makeRecognizer()

        XCTAssertEqual(performTap(on: recognizer, startingAt: 0)?.clickState, 1)
        XCTAssertEqual(performTap(on: recognizer, startingAt: 0.2)?.clickState, 2)
        XCTAssertEqual(performTap(on: recognizer, startingAt: 0.4)?.clickState, 3)
        XCTAssertEqual(performTap(on: recognizer, startingAt: 0.6)?.clickState, 1)
    }

    func testSlowSecondTapResetsClickState() {
        let recognizer = makeRecognizer()

        XCTAssertEqual(performTap(on: recognizer, startingAt: 0)?.clickState, 1)
        // Well past the 0.5 s double-click interval.
        XCTAssertEqual(performTap(on: recognizer, startingAt: 1.0)?.clickState, 1)
    }

    func testCursorMovementBetweenTapsResetsClickState() {
        let recognizer = makeRecognizer()

        XCTAssertEqual(performTap(on: recognizer, startingAt: 0)?.clickState, 1)

        // The firmware moved the cursor between the taps (pointer-context
        // frames still move the pointer via relative reports).
        cursorLocation = .init(x: 160, y: 100)
        let secondTap = performTap(on: recognizer, startingAt: 0.2)
        XCTAssertEqual(secondTap, .init(clickState: 1, location: .init(x: 160, y: 100)))
    }

    func testUnavailableCursorLocationSuppressesTheClick() {
        let recognizer = makeRecognizer()
        cursorLocation = nil
        XCTAssertNil(performTap(on: recognizer))
    }
}
