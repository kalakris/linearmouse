// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

/// Turns a stream of absolute touch frames (`TouchStreamFrame`) into
/// trackpad-style scroll gesture events.
///
/// The engine is a pure state machine with no timers or I/O of its own:
/// `handle(frame:)` is called for every parsed frame and `momentumTick(at:)`
/// is called by the owner at a fixed cadence (~120 Hz) whenever
/// `wantsMomentumTicks` is true. This keeps the frame → phase/momentum logic
/// fully unit-testable with synthetic frames.
///
/// Gesture model:
/// - A scroll-mode touch-down begins a gesture (`.touchBegan`).
/// - Every subsequent scroll-mode sample emits `.touchChanged` with a deltaY
///   derived from the change in absolute Y, scaled by `Config.pointsPerCount`.
/// - Lift-off emits `.touchEnded`; if the measured lift-off velocity is high
///   enough, the engine enters momentum and the owner's decay timer produces
///   `.momentumBegan`/`.momentumChanged` deltas until the velocity decays away
///   (`.momentumEnded`).
/// - A touch-down during momentum cancels the momentum immediately
///   (`.momentumEnded` followed by `.touchBegan`) — the "catch" gesture.
///
/// Vertical only; horizontal scrolling is out of scope for the prototype.
final class TouchScrollEngine {
    struct Config: Equatable {
        /// Screen points of scroll per Cirque touch count.
        var pointsPerCount = Configuration.TouchStream.defaultScale

        /// When false (default), a finger moving toward increasing Cirque Y
        /// produces positive CGEvent deltaY (scroll-up). Set to flip.
        var invert = false

        var directionSign: Double {
            invert ? -1 : 1
        }
    }

    enum Event: Equatable {
        case touchBegan
        case touchChanged(deltaY: Double)
        case touchEnded
        case momentumBegan(deltaY: Double)
        case momentumChanged(deltaY: Double)
        case momentumEnded
    }

    private enum State {
        case idle
        case touching
        case momentum
    }

    // MARK: - Tuning constants

    /// Only samples this recent (relative to lift-off) contribute to the
    /// momentum seed velocity. A finger that stops and then lifts therefore
    /// yields ~zero velocity and no momentum.
    private static let velocityWindow: TimeInterval = 0.1

    /// Minimum measured lift-off speed (points/second) required to start
    /// momentum at all.
    private static let minMomentumVelocity = 100.0

    /// Safety cap for the momentum seed (points/second).
    private static let maxMomentumVelocity = 8000.0

    /// Exponential decay time constant for momentum velocity. 0.83 s matches
    /// a decay factor of ~0.99 per 120 Hz tick, close to the feel of the
    /// smoothed scrolling engine's default momentum.
    private static let decayTimeConstant: TimeInterval = 0.83

    /// Momentum ends once the decayed velocity drops below this (points/second).
    private static let stopVelocity = 10.0

    /// Per-frame position jumps larger than this many Cirque counts are
    /// treated as sensor glitches: the position is re-anchored without
    /// emitting a huge delta.
    private static let maxPlausibleStepCounts = 512.0

    /// The pad this engine scrolls for. pad_id 1 (left pad) is reserved by
    /// the protocol and ignored for now.
    private static let scrollPadID: UInt8 = 0

    // MARK: - State

    var config: Config

    private var state: State = .idle
    private var lastY: Double = 0
    private var samples: [(y: Double, timestamp: TimeInterval)] = []
    private var momentumVelocity = 0.0
    private var momentumBegan = false
    private var lastMomentumTimestamp: TimeInterval = 0

    init(config: Config = .init()) {
        self.config = config
    }

    /// True while the owner should drive `momentumTick(at:)` at ~120 Hz.
    var wantsMomentumTicks: Bool {
        state == .momentum
    }

    // MARK: - Frame input

    func handle(frame: TouchStreamFrame) -> [Event] {
        guard frame.padID == Self.scrollPadID else {
            return []
        }

        if frame.touched, frame.scrollMode {
            return handleScrollTouch(frame: frame)
        }

        if !frame.touched {
            return handleRelease(frame: frame)
        }

        // touched, but not in scroll mode: pointer-time frames. The firmware
        // handles the pointer via its normal relative reports, so these are
        // ignored for scrolling — except that a gesture in progress ends
        // (without momentum) when the scroll layer is released mid-touch.
        if state == .touching {
            reset()
            return [.touchEnded]
        }

        return []
    }

    /// Close out any gesture in progress (device disconnected, feature
    /// disabled, app stopping). Returns the events needed to leave the
    /// synthetic event stream in a consistent state.
    func interrupt() -> [Event] {
        defer {
            reset()
        }

        switch state {
        case .idle:
            return []
        case .touching:
            return [.touchEnded]
        case .momentum:
            return momentumBegan ? [.momentumEnded] : []
        }
    }

    private func handleScrollTouch(frame: TouchStreamFrame) -> [Event] {
        let y = Double(frame.y)

        switch state {
        case .idle:
            beginTouch(y: y, timestamp: frame.timestamp)
            return [.touchBegan]

        case .momentum:
            // The "catch": a finger touching down while coasting stops the
            // scroll dead, exactly like a real trackpad.
            let hadBegunMomentum = momentumBegan
            beginTouch(y: y, timestamp: frame.timestamp)
            return hadBegunMomentum ? [.momentumEnded, .touchBegan] : [.touchBegan]

        case .touching:
            var deltaCounts = y - lastY
            if abs(deltaCounts) > Self.maxPlausibleStepCounts {
                deltaCounts = 0
            }
            lastY = y
            appendSample(y: y, timestamp: frame.timestamp)
            let deltaY = deltaCounts * config.pointsPerCount * config.directionSign
            return [.touchChanged(deltaY: deltaY)]
        }
    }

    private func handleRelease(frame: TouchStreamFrame) -> [Event] {
        guard state == .touching else {
            // A stray release while idle or coasting carries no information.
            return []
        }

        // Do not trust x/y on the release report — only the flags matter.
        let velocity = liftOffVelocity()

        if abs(velocity) >= Self.minMomentumVelocity {
            state = .momentum
            momentumVelocity = velocity.clamped(to: -Self.maxMomentumVelocity ... Self.maxMomentumVelocity)
            momentumBegan = false
            lastMomentumTimestamp = frame.timestamp
            samples.removeAll(keepingCapacity: true)
            return [.touchEnded]
        }

        reset()
        return [.touchEnded]
    }

    private func beginTouch(y: Double, timestamp: TimeInterval) {
        state = .touching
        lastY = y
        momentumVelocity = 0
        momentumBegan = false
        samples.removeAll(keepingCapacity: true)
        appendSample(y: y, timestamp: timestamp)
    }

    private func appendSample(y: Double, timestamp: TimeInterval) {
        samples.append((y: y, timestamp: timestamp))
        let cutoff = timestamp - Self.velocityWindow
        samples.removeAll { $0.timestamp < cutoff }
    }

    /// Velocity in scroll points/second (already scaled and direction-adjusted),
    /// measured across the recent-sample window at the moment of lift-off.
    private func liftOffVelocity() -> Double {
        guard let first = samples.first, let last = samples.last else {
            return 0
        }

        let dt = last.timestamp - first.timestamp
        guard dt >= 0.005 else {
            return 0
        }

        let countsPerSecond = (last.y - first.y) / dt
        return countsPerSecond * config.pointsPerCount * config.directionSign
    }

    // MARK: - Momentum

    func momentumTick(at timestamp: TimeInterval) -> [Event] {
        guard state == .momentum else {
            return []
        }

        let dt = (timestamp - lastMomentumTimestamp).clamped(to: 1.0 / 240.0 ... 1.0 / 24.0)
        lastMomentumTimestamp = timestamp

        momentumVelocity *= exp(-dt / Self.decayTimeConstant)

        guard abs(momentumVelocity) > Self.stopVelocity else {
            let hadBegunMomentum = momentumBegan
            reset()
            return hadBegunMomentum ? [.momentumEnded] : []
        }

        let deltaY = momentumVelocity * dt
        if momentumBegan {
            return [.momentumChanged(deltaY: deltaY)]
        }

        momentumBegan = true
        return [.momentumBegan(deltaY: deltaY)]
    }

    private func reset() {
        state = .idle
        momentumVelocity = 0
        momentumBegan = false
        samples.removeAll(keepingCapacity: true)
    }
}
