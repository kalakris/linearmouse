// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class TouchScrollEngineTests: XCTestCase {
    private static let frameInterval: TimeInterval = 0.01 // ~100 Hz device cadence
    private static let tickInterval: TimeInterval = 1.0 / 120.0

    private func makeEngine(
        pointsPerCount: Double = 0.25,
        invert: Bool = false,
        axis: Configuration.TouchStream.Axis = .y,
        acceleration: TouchScrollEngine.Config.Acceleration = .init()
    ) -> TouchScrollEngine {
        TouchScrollEngine(config: .init(
            pointsPerCount: pointsPerCount,
            invert: invert,
            axis: axis,
            acceleration: acceleration
        ))
    }

    private func scrollFrame(y: Int, at timestamp: TimeInterval, pad: UInt8 = 0) -> TouchStreamFrame {
        .init(padID: pad, x: 1000, y: y, z: 40, touched: true, scrollMode: true, timestamp: timestamp)
    }

    private func pointerFrame(y: Int, at timestamp: TimeInterval) -> TouchStreamFrame {
        .init(x: 1000, y: y, z: 40, touched: true, scrollMode: false, timestamp: timestamp)
    }

    private func releaseFrame(at timestamp: TimeInterval, scrollMode: Bool = true) -> TouchStreamFrame {
        .init(touched: false, scrollMode: scrollMode, timestamp: timestamp)
    }

    /// Drives a fast steady drag and lift-off; returns (dragEvents, liftTime).
    private func performFlick(
        on engine: TouchScrollEngine,
        frames: Int = 12,
        countsPerFrame: Int = 25
    ) -> (events: [TouchScrollEngine.Event], liftTime: TimeInterval) {
        var events: [TouchScrollEngine.Event] = []
        var y = 500
        var timestamp: TimeInterval = 0

        for step in 0 ..< frames {
            timestamp = Double(step) * Self.frameInterval
            events += engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += countsPerFrame
        }

        timestamp += Self.frameInterval
        events += engine.handle(frame: releaseFrame(at: timestamp))
        return (events, timestamp)
    }

    private func drainMomentum(
        on engine: TouchScrollEngine,
        from startTime: TimeInterval,
        maxTicks: Int = 2000
    ) -> [TouchScrollEngine.Event] {
        var events: [TouchScrollEngine.Event] = []
        var timestamp = startTime

        for _ in 0 ..< maxTicks {
            guard engine.wantsMomentumTicks else {
                break
            }
            timestamp += Self.tickInterval
            events += engine.momentumTick(at: timestamp)
        }

        return events
    }

    // MARK: - Touch, drag, lift with momentum

    func testDragAndFlickProducesPhasesAndMomentum() {
        let engine = makeEngine()
        let (dragEvents, liftTime) = performFlick(on: engine)

        XCTAssertEqual(dragEvents.first, .touchBegan)
        let changedDeltas: [Double] = dragEvents.compactMap {
            if case let .touchChanged(deltaY) = $0 { return deltaY } else { return nil }
        }
        XCTAssertEqual(changedDeltas.count, 11)
        // 25 counts * 0.25 points per count per frame.
        XCTAssertTrue(changedDeltas.allSatisfy { abs($0 - 6.25) < 1e-9 })
        XCTAssertEqual(dragEvents.last, .touchEnded)

        XCTAssertTrue(engine.wantsMomentumTicks)

        let momentumEvents = drainMomentum(on: engine, from: liftTime)
        guard case let .momentumBegan(firstDelta) = momentumEvents.first else {
            XCTFail("Expected momentumBegan first, got \(String(describing: momentumEvents.first))")
            return
        }
        XCTAssertGreaterThan(firstDelta, 0)
        XCTAssertTrue(momentumEvents.dropFirst().dropLast().allSatisfy {
            if case .momentumChanged = $0 { return true } else { return false }
        })
        XCTAssertEqual(momentumEvents.last, .momentumEnded)
        XCTAssertFalse(engine.wantsMomentumTicks)

        // Momentum deltas decay monotonically.
        let momentumDeltas: [Double] = momentumEvents.compactMap {
            switch $0 {
            case let .momentumBegan(deltaY), let .momentumChanged(deltaY):
                return deltaY
            default:
                return nil
            }
        }
        XCTAssertGreaterThan(momentumDeltas.count, 10)
        XCTAssertTrue(zip(momentumDeltas, momentumDeltas.dropFirst()).allSatisfy { $0 >= $1 })
        XCTAssertTrue(momentumDeltas.allSatisfy { $0 > 0 })
    }

    // MARK: - Drag, stop, lift: no momentum

    func testStopBeforeLiftYieldsNoMomentum() {
        let engine = makeEngine()
        var events: [TouchScrollEngine.Event] = []
        var timestamp: TimeInterval = 0

        // Fast drag...
        var y = 500
        for step in 0 ..< 10 {
            timestamp = Double(step) * Self.frameInterval
            events += engine.handle(frame: scrollFrame(y: y, at: timestamp))
            y += 25
        }

        // ...then hold still for 300 ms (device keeps streaming while touched)...
        for _ in 0 ..< 30 {
            timestamp += Self.frameInterval
            events += engine.handle(frame: scrollFrame(y: y, at: timestamp))
        }

        // ...then lift.
        timestamp += Self.frameInterval
        events += engine.handle(frame: releaseFrame(at: timestamp))

        XCTAssertEqual(events.last, .touchEnded)
        XCTAssertFalse(engine.wantsMomentumTicks)
        XCTAssertTrue(engine.momentumTick(at: timestamp + Self.tickInterval).isEmpty)
    }

    // MARK: - The catch: touch-down during momentum cancels it

    func testTouchDownDuringMomentumCancelsItImmediately() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)

        // Let momentum begin and coast for a few ticks.
        var timestamp = liftTime
        var sawMomentumBegan = false
        for _ in 0 ..< 10 {
            timestamp += Self.tickInterval
            for event in engine.momentumTick(at: timestamp) {
                if case .momentumBegan = event {
                    sawMomentumBegan = true
                }
            }
        }
        XCTAssertTrue(sawMomentumBegan)
        XCTAssertTrue(engine.wantsMomentumTicks)

        // A resting finger touches down: momentum must end instantly and a
        // fresh gesture must begin.
        let catchEvents = engine.handle(frame: scrollFrame(y: 900, at: timestamp + Self.frameInterval))
        XCTAssertEqual(catchEvents, [.momentumEnded, .touchBegan])
        XCTAssertFalse(engine.wantsMomentumTicks)
        XCTAssertTrue(engine.momentumTick(at: timestamp + 1).isEmpty)

        // The caught gesture keeps working normally.
        let followUp = engine.handle(
            frame: scrollFrame(y: 910, at: timestamp + Self.frameInterval * 2)
        )
        XCTAssertEqual(followUp, [.touchChanged(deltaY: 2.5)])
    }

    // MARK: - Direction and scale

    func testInvertFlipsDeltaSignAndMomentumDirection() {
        let engine = makeEngine(invert: true)
        let (dragEvents, liftTime) = performFlick(on: engine)

        let changedDeltas: [Double] = dragEvents.compactMap {
            if case let .touchChanged(deltaY) = $0 { return deltaY } else { return nil }
        }
        XCTAssertTrue(changedDeltas.allSatisfy { $0 < 0 })

        let momentumEvents = drainMomentum(on: engine, from: liftTime)
        guard case let .momentumBegan(firstDelta) = momentumEvents.first else {
            XCTFail("Expected momentum to begin")
            return
        }
        XCTAssertLessThan(firstDelta, 0)
    }

    func testAxisXDrivesDeltasFromRawXAndComposesWithInvert() {
        // Rotated pad mount (Go60): physical up/down motion changes raw X.
        let engine = makeEngine(axis: .x)
        _ = engine.handle(frame: .init(x: 1000, y: 500, z: 40, touched: true, scrollMode: true, timestamp: 0))
        let events = engine.handle(
            frame: .init(x: 1030, y: 500, z: 40, touched: true, scrollMode: true, timestamp: Self.frameInterval)
        )
        XCTAssertEqual(events, [.touchChanged(deltaY: 7.5)])

        // Raw-Y movement carries no scroll information on axis x.
        let yOnly = engine.handle(
            frame: .init(x: 1030, y: 900, z: 40, touched: true, scrollMode: true, timestamp: Self.frameInterval * 2)
        )
        XCTAssertEqual(yOnly, [.touchChanged(deltaY: 0)])

        // invert composes with the axis selection unchanged.
        let invertedEngine = makeEngine(invert: true, axis: .x)
        _ = invertedEngine.handle(
            frame: .init(x: 1000, y: 500, z: 40, touched: true, scrollMode: true, timestamp: 0)
        )
        let invertedEvents = invertedEngine.handle(
            frame: .init(x: 1030, y: 500, z: 40, touched: true, scrollMode: true, timestamp: Self.frameInterval)
        )
        XCTAssertEqual(invertedEvents, [.touchChanged(deltaY: -7.5)])
    }

    func testScaleAppliesToDeltas() {
        let engine = makeEngine(pointsPerCount: 1.0)
        _ = engine.handle(frame: scrollFrame(y: 500, at: 0))
        let events = engine.handle(frame: scrollFrame(y: 530, at: Self.frameInterval))
        XCTAssertEqual(events, [.touchChanged(deltaY: 30)])
    }

    // MARK: - Acceleration (velocity-dependent gain)

    /// Steady drag at `countsPerFrame` per ~100 Hz frame; returns the emitted
    /// touchChanged deltas.
    private func steadyDragDeltas(
        acceleration: TouchScrollEngine.Config.Acceleration,
        countsPerFrame: Int,
        frames: Int = 10
    ) -> [Double] {
        let engine = makeEngine(acceleration: acceleration)
        var deltas: [Double] = []
        var y = 200

        for step in 0 ..< frames {
            let events = engine.handle(frame: scrollFrame(y: y, at: Double(step) * Self.frameInterval))
            for case let .touchChanged(deltaY) in events {
                deltas.append(deltaY)
            }
            y += countsPerFrame
        }

        return deltas
    }

    /// Expected steady-state gain for a constant-speed drag with the default
    /// curve: clamp(sqrt(speed / 800), 0.4, 3).
    private func defaultCurveGain(countsPerFrame: Int) -> Double {
        let speed = Double(countsPerFrame) / Self.frameInterval
        return pow(speed / 800.0, 0.5).clamped(to: 0.4 ... 3.0)
    }

    func testAccelerationExponentZeroMatchesDisabledAndLinear() {
        let linear = makeEngine()
        let disabled = makeEngine(acceleration: .init(enabled: false, exponent: 0.7))
        let exponentZero = makeEngine(acceleration: .init(enabled: true, exponent: 0))

        let (linearEvents, linearLift) = performFlick(on: linear)
        let (disabledEvents, disabledLift) = performFlick(on: disabled)
        let (exponentZeroEvents, exponentZeroLift) = performFlick(on: exponentZero)

        XCTAssertEqual(disabledEvents, linearEvents)
        XCTAssertEqual(exponentZeroEvents, linearEvents)

        // The momentum seed and decay must match too.
        let linearMomentum = drainMomentum(on: linear, from: linearLift)
        XCTAssertFalse(linearMomentum.isEmpty)
        XCTAssertEqual(drainMomentum(on: disabled, from: disabledLift), linearMomentum)
        XCTAssertEqual(drainMomentum(on: exponentZero, from: exponentZeroLift), linearMomentum)
    }

    func testAccelerationAttenuatesSlowDragsAndBoostsFastDrags() {
        // Slow drag: 3 counts/frame = 300 counts/s, below the 800 counts/s
        // reference speed, so gain < 1.
        let slowLinear = steadyDragDeltas(acceleration: .init(), countsPerFrame: 3)
        let slowAccelerated = steadyDragDeltas(acceleration: .init(enabled: true), countsPerFrame: 3)
        XCTAssertEqual(slowAccelerated.count, slowLinear.count)
        for (accelerated, linear) in zip(slowAccelerated, slowLinear) {
            XCTAssertLessThan(accelerated, linear)
            XCTAssertGreaterThan(accelerated, 0)
        }

        // Fast drag: 25 counts/frame = 2500 counts/s, above reference, gain > 1.
        let fastLinear = steadyDragDeltas(acceleration: .init(), countsPerFrame: 25)
        let fastAccelerated = steadyDragDeltas(acceleration: .init(enabled: true), countsPerFrame: 25)
        for (accelerated, linear) in zip(fastAccelerated, fastLinear) {
            XCTAssertGreaterThan(accelerated, linear)
        }
    }

    func testAccelerationHasNoSlowStartDeadZone() {
        // A steady drag exactly at the reference speed (8 counts/frame =
        // 800 counts/s) must have gain 1 from the very first movement frame:
        // the speed smoother seeds from the first observed instantaneous
        // speed rather than ramping up from zero.
        let deltas = steadyDragDeltas(acceleration: .init(enabled: true), countsPerFrame: 8)
        XCTAssertEqual(deltas.count, 9)
        for delta in deltas {
            XCTAssertEqual(delta, 8 * 0.25, accuracy: 1e-9)
        }
    }

    func testAccelerationGainClampsAtMinAndMax() {
        // 1 count/frame = 100 counts/s: raw gain sqrt(100/800) ≈ 0.354,
        // clamped up to minGain 0.4.
        let crawlDeltas = steadyDragDeltas(acceleration: .init(enabled: true), countsPerFrame: 1)
        XCTAssertEqual(defaultCurveGain(countsPerFrame: 1), 0.4)
        for delta in crawlDeltas {
            XCTAssertEqual(delta, 1 * 0.25 * 0.4, accuracy: 1e-9)
        }

        // 100 counts/frame = 10000 counts/s: raw gain sqrt(12.5) ≈ 3.54,
        // clamped down to maxGain 3.
        let sprintDeltas = steadyDragDeltas(acceleration: .init(enabled: true), countsPerFrame: 100)
        XCTAssertEqual(defaultCurveGain(countsPerFrame: 100), 3.0)
        for delta in sprintDeltas {
            XCTAssertEqual(delta, 100 * 0.25 * 3.0, accuracy: 1e-9)
        }
    }

    func testAccelerationMomentumSeedReflectsBoostedVelocity() {
        let linear = makeEngine()
        let accelerated = makeEngine(acceleration: .init(enabled: true))

        let (_, linearLift) = performFlick(on: linear)
        let (_, acceleratedLift) = performFlick(on: accelerated)
        XCTAssertTrue(linear.wantsMomentumTicks)
        XCTAssertTrue(accelerated.wantsMomentumTicks)

        guard
            case let .momentumBegan(linearSeed)? = drainMomentum(on: linear, from: linearLift).first,
            case let .momentumBegan(acceleratedSeed)? = drainMomentum(on: accelerated, from: acceleratedLift).first
        else {
            XCTFail("Expected both engines to begin momentum")
            return
        }

        // The steady 2500 counts/s flick has constant gain sqrt(2500/800),
        // so the output-side (on-screen) lift-off velocity — and therefore
        // the momentum seed — is boosted by exactly that factor.
        let expectedGain = defaultCurveGain(countsPerFrame: 25)
        XCTAssertGreaterThan(expectedGain, 1)
        XCTAssertEqual(acceleratedSeed, linearSeed * expectedGain, accuracy: 1e-6)
    }

    // MARK: - Frames that must be ignored

    func testPointerTimeFramesAreIgnored() {
        let engine = makeEngine()
        var events: [TouchScrollEngine.Event] = []

        for step in 0 ..< 5 {
            events += engine.handle(
                frame: pointerFrame(y: 500 + step * 25, at: Double(step) * Self.frameInterval)
            )
        }
        events += engine.handle(frame: releaseFrame(at: 0.06, scrollMode: false))

        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(engine.wantsMomentumTicks)
    }

    func testPointerTimeFramesDoNotCatchMomentum() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)
        _ = engine.momentumTick(at: liftTime + Self.tickInterval)
        XCTAssertTrue(engine.wantsMomentumTicks)

        // Firmware owns the pointer during these frames; scrolling ignores them.
        let events = engine.handle(frame: pointerFrame(y: 700, at: liftTime + 0.05))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(engine.wantsMomentumTicks)
    }

    func testLeftPadFramesAreIgnored() {
        let engine = makeEngine()
        let events = engine.handle(frame: scrollFrame(y: 500, at: 0, pad: 1))
        XCTAssertTrue(events.isEmpty)
    }

    func testScrollModeDroppedMidTouchEndsGestureWithoutMomentum() {
        let engine = makeEngine()
        var events: [TouchScrollEngine.Event] = []
        var y = 500
        for step in 0 ..< 8 {
            events += engine.handle(frame: scrollFrame(y: y, at: Double(step) * Self.frameInterval))
            y += 25
        }
        XCTAssertEqual(events.first, .touchBegan)

        // The user releases the scroll layer while still touching.
        let endEvents = engine.handle(frame: pointerFrame(y: y, at: 0.09))
        XCTAssertEqual(endEvents, [.touchEnded])
        XCTAssertFalse(engine.wantsMomentumTicks)
    }

    // MARK: - Robustness

    func testImplausiblePositionJumpDoesNotEmitHugeDelta() {
        let engine = makeEngine()
        _ = engine.handle(frame: scrollFrame(y: 100, at: 0))
        let events = engine.handle(frame: scrollFrame(y: 1500, at: Self.frameInterval))
        XCTAssertEqual(events, [.touchChanged(deltaY: 0)])
    }

    func testInterruptDuringTouchEmitsTouchEnded() {
        let engine = makeEngine()
        _ = engine.handle(frame: scrollFrame(y: 500, at: 0))
        XCTAssertEqual(engine.interrupt(), [.touchEnded])
        XCTAssertFalse(engine.wantsMomentumTicks)
    }

    func testInterruptDuringMomentumEmitsMomentumEnded() {
        let engine = makeEngine()
        let (_, liftTime) = performFlick(on: engine)
        _ = engine.momentumTick(at: liftTime + Self.tickInterval)
        XCTAssertEqual(engine.interrupt(), [.momentumEnded])
        XCTAssertFalse(engine.wantsMomentumTicks)
    }
}

final class TouchStreamFrameTests: XCTestCase {
    func testParsesWellFormedPayload() {
        // pad 0, x = 0x0403 (1027), y = 0x0201 (513), z = 42, touched + scroll mode.
        let frame = TouchStreamFrame(
            reportBytes: [0x00, 0x03, 0x04, 0x01, 0x02, 0x2A, 0x03],
            timestamp: 1.5
        )
        XCTAssertEqual(frame?.padID, 0)
        XCTAssertEqual(frame?.x, 1027)
        XCTAssertEqual(frame?.y, 513)
        XCTAssertEqual(frame?.z, 42)
        XCTAssertEqual(frame?.touched, true)
        XCTAssertEqual(frame?.scrollMode, true)
        XCTAssertEqual(frame?.timestamp, 1.5)
    }

    func testParsesFlagCombinations() {
        let release = TouchStreamFrame(
            reportBytes: [0x00, 0, 0, 0, 0, 0, 0x00],
            timestamp: 0
        )
        XCTAssertEqual(release?.touched, false)
        XCTAssertEqual(release?.scrollMode, false)

        let pointerTime = TouchStreamFrame(
            reportBytes: [0x00, 0, 0, 0, 0, 10, 0x01],
            timestamp: 0
        )
        XCTAssertEqual(pointerTime?.touched, true)
        XCTAssertEqual(pointerTime?.scrollMode, false)

        // Reserved flag bits must not confuse parsing.
        let reservedBits = TouchStreamFrame(
            reportBytes: [0x01, 0, 0, 0, 0, 10, 0xFF],
            timestamp: 0
        )
        XCTAssertEqual(reservedBits?.padID, 1)
        XCTAssertEqual(reservedBits?.touched, true)
        XCTAssertEqual(reservedBits?.scrollMode, true)
    }

    func testRejectsShortReports() {
        XCTAssertNil(TouchStreamFrame(reportBytes: [], timestamp: 0))
        XCTAssertNil(TouchStreamFrame(reportBytes: [0x00, 0x01], timestamp: 0))
        XCTAssertNil(TouchStreamFrame(reportBytes: [0, 0, 0, 0, 0, 0], timestamp: 0))
    }

    func testIgnoresTrailingPadding() {
        let frame = TouchStreamFrame(
            reportBytes: [0x00, 0x03, 0x04, 0x01, 0x02, 0x2A, 0x03, 0x00, 0x00],
            timestamp: 0
        )
        XCTAssertEqual(frame?.x, 1027)
        XCTAssertEqual(frame?.scrollMode, true)
    }
}
