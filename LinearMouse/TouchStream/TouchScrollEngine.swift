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
///   derived from the change in the absolute coordinate selected by
///   `Config.axis` (Y by default), scaled by `Config.pointsPerCount` and, when
///   `Config.acceleration` is enabled, by a smooth velocity-dependent gain
///   (see `Config.Acceleration`). Rotated pad mounts (e.g. the Go60, whose
///   firmware streams raw coordinates without its `rotate-90; y-invert;`
///   pointer transforms) select X instead.
/// - Lift-off emits `.touchEnded`; if the measured lift-off velocity is high
///   enough, the engine enters momentum and the owner's decay timer produces
///   `.momentumBegan`/`.momentumChanged` deltas until the velocity decays away
///   (`.momentumEnded`).
/// - A touch-down during momentum cancels the momentum immediately
///   (`.momentumEnded` followed by `.touchBegan`) — the "catch" gesture.
///
/// Vertical only; horizontal scrolling is out of scope for the prototype.
///
/// The engine is pad-agnostic: `TouchStreamManager` arbitrates between the
/// device's pads and only ever forwards one pad's frames per gesture, so a
/// single engine instance serves both Go60 trackpads.
final class TouchScrollEngine {
    struct Config: Equatable {
        /// Screen points of scroll per Cirque touch count.
        var pointsPerCount = Scheme.Scrolling.TouchStream.defaultScale

        /// When false (default), a finger moving toward an increasing raw
        /// coordinate (on the selected axis) produces positive CGEvent deltaY
        /// (scroll-up). Set to flip. Derived by the owner from the device's
        /// self-reported orientation plus the user direction override (see
        /// `TouchStreamCapabilities`).
        var invert = false

        /// The raw Cirque coordinate that feeds the position/velocity math.
        /// Derived by the owner from the device's self-reported orientation.
        var axis: TouchStreamAxis = .y

        /// Velocity-dependent gain ("ballistics"). Disabled by default, which
        /// preserves the plain linear counts → points mapping exactly.
        var acceleration = Acceleration()

        /// Momentum (coasting) tuning.
        var momentum = Momentum()

        var directionSign: Double {
            invert ? -1 : 1
        }

        /// Apple-trackpad-style ballistics: slow finger motion scrolls with
        /// sub-linear precision, fast flicks travel super-linearly.
        ///
        /// The gain applied to each frame's delta is
        /// `clamp((smoothedSpeed / referenceSpeed) ^ exponent, minGain, maxGain)`
        /// where `smoothedSpeed` is the exponentially smoothed finger speed in
        /// raw Cirque counts per second. With `exponent` 0 the curve is the
        /// identity (gain 1 everywhere).
        struct Acceleration: Equatable {
            var enabled = false
            var exponent = Scheme.Scrolling.TouchStream.Acceleration.defaultExponent
            var referenceSpeed = Scheme.Scrolling.TouchStream.Acceleration.defaultReferenceSpeed
            var minGain = Scheme.Scrolling.TouchStream.Acceleration.defaultMinGain
            var maxGain = Scheme.Scrolling.TouchStream.Acceleration.defaultMaxGain
        }

        /// Momentum (coasting after lift-off) tuning, exposed through the
        /// scheme's `scrolling.touchStream.momentum` configuration.
        struct Momentum: Equatable {
            /// Exponential decay time constant for the momentum velocity, in
            /// seconds.
            var decayTimeConstant = Scheme.Scrolling.TouchStream.Momentum.defaultDecayTimeConstant

            /// Minimum measured lift-off speed (points/second) required to
            /// start momentum at all.
            var startThreshold = Scheme.Scrolling.TouchStream.Momentum.defaultStartThreshold

            /// Safety cap for the momentum seed (points/second).
            var maxSpeed = Scheme.Scrolling.TouchStream.Momentum.defaultMaxSpeed
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

    /// Momentum ends once the decayed velocity drops below this (points/second).
    private static let stopVelocity = 10.0

    /// Exponential smoothing time constant for the finger-speed estimate that
    /// drives the acceleration gain. ~40 ms (about 4 frames at the pad's
    /// ~100 Hz cadence) keeps the gain from jittering frame to frame while
    /// still responding quickly to a flick.
    private static let speedSmoothingTimeConstant: TimeInterval = 0.04

    /// Per-frame position jumps larger than this many Cirque counts are
    /// treated as sensor glitches: the position is re-anchored without
    /// emitting a huge delta.
    private static let maxPlausibleStepCounts = 512.0

    // MARK: - State

    var config: Config

    private var state: State = .idle
    private var lastPosition: Double = 0
    private var lastTimestamp: TimeInterval = 0

    /// Exponentially smoothed finger speed in raw counts/second, or nil until
    /// the first movement frame of the touch. Seeding from the first observed
    /// instantaneous speed (rather than ramping up from zero) means a slow
    /// deliberate drag gets its sub-unity gain immediately instead of
    /// starting in a minGain dead zone, and a fast flick gets boosted from
    /// its very first frames.
    private var smoothedSpeed: Double?

    /// Accumulated gain-adjusted position in raw counts. The momentum seed is
    /// measured from this output-side position so a boosted flick coasts as
    /// fast as it scrolled, and a slow (attenuated) release stays gentle.
    private var outputPosition: Double = 0

    /// Recent output-side positions used to measure the lift-off velocity.
    private var samples: [(position: Double, timestamp: TimeInterval)] = []
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

    /// True while a gesture is in progress (touching or coasting).
    /// `TouchStreamManager` uses this to clear its scroll-pad claim once a
    /// gesture has fully ended.
    var isActive: Bool {
        state != .idle
    }

    // MARK: - Frame input

    func handle(frame: TouchStreamFrame) -> [Event] {
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

    /// The raw coordinate driving the scroll position math, per `Config.axis`.
    private func position(of frame: TouchStreamFrame) -> Double {
        switch config.axis {
        case .x:
            Double(frame.x)
        case .y:
            Double(frame.y)
        }
    }

    private func handleScrollTouch(frame: TouchStreamFrame) -> [Event] {
        let position = position(of: frame)

        switch state {
        case .idle:
            beginTouch(position: position, timestamp: frame.timestamp)
            return [.touchBegan]

        case .momentum:
            // The "catch": a finger touching down while coasting stops the
            // scroll dead, exactly like a real trackpad.
            let hadBegunMomentum = momentumBegan
            beginTouch(position: position, timestamp: frame.timestamp)
            return hadBegunMomentum ? [.momentumEnded, .touchBegan] : [.touchBegan]

        case .touching:
            var deltaCounts = position - lastPosition
            if abs(deltaCounts) > Self.maxPlausibleStepCounts {
                deltaCounts = 0
            }
            let dt = frame.timestamp - lastTimestamp
            lastPosition = position
            lastTimestamp = frame.timestamp

            let gain = updatedGain(deltaCounts: deltaCounts, dt: dt)
            outputPosition += deltaCounts * gain
            appendSample(position: outputPosition, timestamp: frame.timestamp)
            let deltaY = deltaCounts * gain * config.pointsPerCount * config.directionSign
            return [.touchChanged(deltaY: deltaY)]
        }
    }

    /// Updates the smoothed finger-speed estimate with this frame's movement
    /// and returns the acceleration gain to apply to its delta. Gain is 1
    /// (plain linear behavior) while acceleration is disabled.
    private func updatedGain(deltaCounts: Double, dt: TimeInterval) -> Double {
        let acceleration = config.acceleration
        guard acceleration.enabled else {
            return 1
        }

        if dt > 0 {
            let instantaneousSpeed = abs(deltaCounts) / dt
            if let smoothedSpeed {
                let alpha = 1 - exp(-dt / Self.speedSmoothingTimeConstant)
                self.smoothedSpeed = smoothedSpeed + alpha * (instantaneousSpeed - smoothedSpeed)
            } else {
                smoothedSpeed = instantaneousSpeed
            }
        }

        guard let smoothedSpeed, acceleration.referenceSpeed > 0 else {
            return 1
        }

        // pow(0, 0) == 1, so exponent 0 is the identity even from rest.
        let gain = pow(smoothedSpeed / acceleration.referenceSpeed, acceleration.exponent)
        return gain.clamped(to: acceleration.minGain ... acceleration.maxGain)
    }

    private func handleRelease(frame: TouchStreamFrame) -> [Event] {
        guard state == .touching else {
            // A stray release while idle or coasting carries no information.
            return []
        }

        // Do not trust x/y on the release report — only the flags matter.
        let velocity = liftOffVelocity()

        if abs(velocity) >= config.momentum.startThreshold {
            state = .momentum
            momentumVelocity = velocity.clamped(to: -config.momentum.maxSpeed ... config.momentum.maxSpeed)
            momentumBegan = false
            lastMomentumTimestamp = frame.timestamp
            samples.removeAll(keepingCapacity: true)
            return [.touchEnded]
        }

        reset()
        return [.touchEnded]
    }

    private func beginTouch(position: Double, timestamp: TimeInterval) {
        state = .touching
        lastPosition = position
        lastTimestamp = timestamp
        smoothedSpeed = nil
        outputPosition = 0
        momentumVelocity = 0
        momentumBegan = false
        samples.removeAll(keepingCapacity: true)
        appendSample(position: outputPosition, timestamp: timestamp)
    }

    private func appendSample(position: Double, timestamp: TimeInterval) {
        samples.append((position: position, timestamp: timestamp))
        let cutoff = timestamp - Self.velocityWindow
        samples.removeAll { $0.timestamp < cutoff }
    }

    /// Velocity in scroll points/second (already scaled and direction-adjusted),
    /// measured across the recent-sample window at the moment of lift-off.
    /// Samples are output-side (acceleration gain already applied), so the
    /// momentum seed matches the on-screen speed the drag actually had.
    private func liftOffVelocity() -> Double {
        guard let first = samples.first, let last = samples.last else {
            return 0
        }

        let dt = last.timestamp - first.timestamp
        guard dt >= 0.005 else {
            return 0
        }

        let countsPerSecond = (last.position - first.position) / dt
        return countsPerSecond * config.pointsPerCount * config.directionSign
    }

    // MARK: - Momentum

    func momentumTick(at timestamp: TimeInterval) -> [Event] {
        guard state == .momentum else {
            return []
        }

        let dt = (timestamp - lastMomentumTimestamp).clamped(to: 1.0 / 240.0 ... 1.0 / 24.0)
        lastMomentumTimestamp = timestamp

        momentumVelocity *= exp(-dt / config.momentum.decayTimeConstant)

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
        smoothedSpeed = nil
        outputPosition = 0
        momentumVelocity = 0
        momentumBegan = false
        samples.removeAll(keepingCapacity: true)
    }
}
