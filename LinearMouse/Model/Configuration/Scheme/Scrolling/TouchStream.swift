// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

extension Scheme.Scrolling {
    /// Configuration for the raw touch-stream scrolling pipeline.
    ///
    /// A supported keyboard (currently the MoErgo Go60 right half) streams
    /// absolute Cirque trackpad frames over a vendor-defined HID report.
    /// `TouchStreamManager` consumes them and synthesizes trackpad-style
    /// phased scrolling with momentum.
    ///
    /// Streaming devices self-describe through a feature report
    /// (`TouchStreamCapabilities`): the pad's mounting orientation determines
    /// the scroll axis and default direction automatically. There is no
    /// direction key here at all — the scheme's generic `scrolling.reverse`
    /// (vertical) toggle flips the orientation-derived natural direction,
    /// exactly like it does for every other scrolling mode. The flip is
    /// applied once, at the source, as the engine's output sign; the
    /// event-tap `ReverseScrollingTransformer` deliberately skips
    /// LinearMouse's own synthetic events.
    ///
    /// The device that this configuration applies to is the pointer device of
    /// the same keyboard (same vendor/product ID as the vendor HID
    /// collection), which is how the configuration participates in per-device
    /// scheme matching and merging like every other scrolling setting.
    struct TouchStream: Codable, Equatable, ImplicitInitable {
        /// Whether touch-stream scrolling is active. Defaults to `true` when
        /// the `touchStream` object is present; the feature is entirely off
        /// when the object is absent.
        var enabled: Bool?

        /// Scroll scale in screen points per Cirque touch count.
        var scale: Decimal?

        /// Velocity-dependent scroll gain ("ballistics"). Absent = off.
        var acceleration: Acceleration?

        /// Momentum (coasting after lift-off) tuning. Absent = defaults.
        var momentum: Momentum?

        /// DEPRECATED: host-side tap-to-click for the pointer context.
        /// Firmware now owns tap-to-click; this remains only for older
        /// firmware and defaults to off.
        var tapToClick: TapToClick?

        /// Apple-trackpad-style scroll ballistics: slow drags scroll with
        /// sub-linear precision, fast flicks travel super-linearly.
        ///
        /// The per-frame gain is
        /// `clamp((smoothedSpeed / referenceSpeed) ^ exponent, minGain, maxGain)`
        /// where `smoothedSpeed` is the lightly smoothed finger speed in raw
        /// Cirque counts per second. `exponent` 0 makes the curve the
        /// identity (plain linear scrolling).
        struct Acceleration: Codable, Equatable {
            /// Whether the velocity-dependent gain is active. Like
            /// `tapToClick.enabled`, this defaults to `false` even when the
            /// `acceleration` object is present.
            ///
            /// The UI exposes a single "Scroll acceleration" slider bound to
            /// `exponent`; writing an exponent > 0 also sets
            /// `enabled = true`, and writing exponent 0 sets
            /// `enabled = false` (exponent 0 is the identity curve anyway,
            /// so both spellings behave identically flat).
            var enabled: Bool?

            /// Exponent of the gain curve. 0 is the identity; 0.5 doubles
            /// the gain for every 4x increase in finger speed.
            var exponent: Decimal?

            /// Finger speed in raw counts/second at which the gain is exactly
            /// 1 (the pad reports ~38 counts/mm, so 800 counts/s ≈ 2 cm/s).
            var referenceSpeed: Decimal?

            /// Lower gain clamp, applied to slow-motion frames.
            var minGain: Decimal?

            /// Upper gain clamp, applied to fast flicks.
            var maxGain: Decimal?

            init(
                enabled: Bool? = nil,
                exponent: Decimal? = nil,
                referenceSpeed: Decimal? = nil,
                minGain: Decimal? = nil,
                maxGain: Decimal? = nil
            ) {
                self.enabled = enabled
                self.exponent = exponent
                self.referenceSpeed = referenceSpeed
                self.minGain = minGain
                self.maxGain = maxGain
            }
        }

        /// Momentum ("coasting") tuning: how the scroll velocity measured at
        /// lift-off decays into the momentum phase.
        struct Momentum: Codable, Equatable {
            /// Exponential decay time constant of the momentum velocity, in
            /// seconds. Larger = longer coasting.
            var decayTimeConstant: Decimal?

            /// Minimum lift-off speed, in scroll points/second, required to
            /// enter momentum at all.
            var startThreshold: Decimal?

            /// Safety cap on the momentum seed velocity, in scroll
            /// points/second.
            var maxSpeed: Decimal?

            init(
                decayTimeConstant: Decimal? = nil,
                startThreshold: Decimal? = nil,
                maxSpeed: Decimal? = nil
            ) {
                self.decayTimeConstant = decayTimeConstant
                self.startThreshold = startThreshold
                self.maxSpeed = maxSpeed
            }
        }

        /// DEPRECATED: tap-to-click on pointer-context frames (touched,
        /// scroll mode off). The firmware now implements tap-to-click itself;
        /// keep this off unless running older firmware.
        struct TapToClick: Codable, Equatable {
            /// Whether tap-to-click is active. Unlike the parent `enabled`,
            /// this defaults to `false` even when the object is present.
            var enabled: Bool?

            /// Maximum touch duration in milliseconds for a touch to count as
            /// a tap.
            var maxDurationMs: Decimal?

            /// Maximum movement in raw Cirque counts (max of |Δx|, |Δy| over
            /// the whole touch) for a touch to count as a tap.
            var maxMovement: Decimal?

            init(enabled: Bool? = nil, maxDurationMs: Decimal? = nil, maxMovement: Decimal? = nil) {
                self.enabled = enabled
                self.maxDurationMs = maxDurationMs
                self.maxMovement = maxMovement
            }
        }

        init() {}

        init(
            enabled: Bool? = nil,
            scale: Decimal? = nil,
            acceleration: Acceleration? = nil,
            momentum: Momentum? = nil,
            tapToClick: TapToClick? = nil
        ) {
            self.enabled = enabled
            self.scale = scale
            self.acceleration = acceleration
            self.momentum = momentum
            self.tapToClick = tapToClick
        }
    }
}

extension Scheme.Scrolling.TouchStream {
    static let scaleRange: ClosedRange<Double> = 0.001 ... 10.0
    static let defaultScale = 0.25

    var isEnabled: Bool {
        enabled ?? true
    }

    var resolvedScale: Double {
        (scale?.asTruncatedDouble ?? Self.defaultScale).clamped(to: Self.scaleRange)
    }

    var isTapToClickEnabled: Bool {
        tapToClick?.isEnabled ?? false
    }

    func merge(into touchStream: inout Self) {
        if let enabled {
            touchStream.enabled = enabled
        }

        if let scale {
            touchStream.scale = scale
        }

        if let acceleration {
            if touchStream.acceleration == nil {
                touchStream.acceleration = acceleration
            } else {
                acceleration.merge(into: &touchStream.acceleration!)
            }
        }

        if let momentum {
            if touchStream.momentum == nil {
                touchStream.momentum = momentum
            } else {
                momentum.merge(into: &touchStream.momentum!)
            }
        }

        if let tapToClick {
            if touchStream.tapToClick == nil {
                touchStream.tapToClick = tapToClick
            } else {
                tapToClick.merge(into: &touchStream.tapToClick!)
            }
        }
    }

    func merge(into touchStream: inout Self?) {
        if touchStream == nil {
            touchStream = Self()
        }

        merge(into: &touchStream!)
    }
}

extension Scheme.Scrolling.TouchStream.Acceleration {
    static let exponentRange: ClosedRange<Double> = 0 ... 2
    static let defaultExponent = 0.5

    static let referenceSpeedRange: ClosedRange<Double> = 50 ... 20000
    static let defaultReferenceSpeed = 800.0

    static let minGainRange: ClosedRange<Double> = 0.05 ... 1.0
    static let defaultMinGain = 0.4

    static let maxGainRange: ClosedRange<Double> = 1.0 ... 20.0
    static let defaultMaxGain = 3.0

    var isEnabled: Bool {
        enabled ?? false
    }

    var resolvedExponent: Double {
        (exponent?.asTruncatedDouble ?? Self.defaultExponent).clamped(to: Self.exponentRange)
    }

    var resolvedReferenceSpeed: Double {
        (referenceSpeed?.asTruncatedDouble ?? Self.defaultReferenceSpeed).clamped(to: Self.referenceSpeedRange)
    }

    var resolvedMinGain: Double {
        (minGain?.asTruncatedDouble ?? Self.defaultMinGain).clamped(to: Self.minGainRange)
    }

    var resolvedMaxGain: Double {
        (maxGain?.asTruncatedDouble ?? Self.defaultMaxGain).clamped(to: Self.maxGainRange)
    }

    func merge(into acceleration: inout Self) {
        if let enabled {
            acceleration.enabled = enabled
        }

        if let exponent {
            acceleration.exponent = exponent
        }

        if let referenceSpeed {
            acceleration.referenceSpeed = referenceSpeed
        }

        if let minGain {
            acceleration.minGain = minGain
        }

        if let maxGain {
            acceleration.maxGain = maxGain
        }
    }
}

extension Scheme.Scrolling.TouchStream.Momentum {
    static let decayTimeConstantRange: ClosedRange<Double> = 0.05 ... 5.0

    /// 0.83 s matches a decay factor of ~0.99 per 120 Hz tick, close to the
    /// feel of the smoothed scrolling engine's default momentum.
    static let defaultDecayTimeConstant = 0.83

    static let startThresholdRange: ClosedRange<Double> = 0 ... 5000
    static let defaultStartThreshold = 100.0

    static let maxSpeedRange: ClosedRange<Double> = 100 ... 50000
    static let defaultMaxSpeed = 8000.0

    var resolvedDecayTimeConstant: TimeInterval {
        (decayTimeConstant?.asTruncatedDouble ?? Self.defaultDecayTimeConstant)
            .clamped(to: Self.decayTimeConstantRange)
    }

    var resolvedStartThreshold: Double {
        (startThreshold?.asTruncatedDouble ?? Self.defaultStartThreshold).clamped(to: Self.startThresholdRange)
    }

    var resolvedMaxSpeed: Double {
        (maxSpeed?.asTruncatedDouble ?? Self.defaultMaxSpeed).clamped(to: Self.maxSpeedRange)
    }

    func merge(into momentum: inout Self) {
        if let decayTimeConstant {
            momentum.decayTimeConstant = decayTimeConstant
        }

        if let startThreshold {
            momentum.startThreshold = startThreshold
        }

        if let maxSpeed {
            momentum.maxSpeed = maxSpeed
        }
    }
}

extension Scheme.Scrolling.TouchStream.TapToClick {
    static let maxDurationMsRange: ClosedRange<Double> = 50 ... 1000
    static let defaultMaxDurationMs = 180.0

    static let maxMovementRange: ClosedRange<Double> = 1 ... 500
    static let defaultMaxMovement = 30.0

    var isEnabled: Bool {
        enabled ?? false
    }

    var resolvedMaxDuration: TimeInterval {
        (maxDurationMs?.asTruncatedDouble ?? Self.defaultMaxDurationMs)
            .clamped(to: Self.maxDurationMsRange) / 1000
    }

    var resolvedMaxMovement: Double {
        (maxMovement?.asTruncatedDouble ?? Self.defaultMaxMovement).clamped(to: Self.maxMovementRange)
    }

    func merge(into tapToClick: inout Self) {
        if let enabled {
            tapToClick.enabled = enabled
        }

        if let maxDurationMs {
            tapToClick.maxDurationMs = maxDurationMs
        }

        if let maxMovement {
            tapToClick.maxMovement = maxMovement
        }
    }
}
