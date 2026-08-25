// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

extension Configuration {
    /// Prototype configuration for the raw touch-stream scrolling pipeline.
    ///
    /// A supported keyboard (currently the MoErgo Go60 right half) streams
    /// absolute Cirque trackpad frames over a vendor-defined HID report.
    /// `TouchStreamManager` consumes them and synthesizes trackpad-style
    /// phased scrolling with momentum.
    ///
    /// This intentionally lives at the top level of the configuration rather
    /// than on a scrolling scheme: the touch stream is not driven by CGEvents,
    /// so per-scheme matching (device/app/display) does not naturally apply.
    /// The device itself is matched by hardcoded constants in
    /// `TouchStreamManager` for the prototype.
    struct TouchStream: Codable, Equatable {
        /// Which raw Cirque coordinate feeds the scroll engine. The pads may
        /// be mounted rotated (e.g. the Go60 applies `rotate-90` in firmware
        /// to its relative pointer reports, but streams raw coordinates), in
        /// which case physical up/down motion changes the raw X coordinate.
        enum Axis: String, Codable {
            case x
            case y
        }

        /// Whether touch-stream scrolling is active. Defaults to `true` when
        /// the `touchStream` object is present; the feature is entirely off
        /// when the object is absent.
        var enabled: Bool?

        /// Scroll scale in screen points per Cirque touch count.
        var scale: Decimal?

        /// Inverts the scroll direction. With `invert` unset or `false`, a
        /// finger moving toward an increasing raw coordinate produces
        /// positive (scroll-up) deltas.
        var invert: Bool?

        /// The raw coordinate used for scrolling. Defaults to `y`.
        var axis: Axis?

        /// Velocity-dependent scroll gain ("ballistics"). Absent = off.
        var acceleration: Acceleration?

        /// Host-side tap-to-click for the pointer context. Absent = off.
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

        /// Tap-to-click on pointer-context frames (touched, scroll mode off).
        ///
        /// The Cirque pads lost their hardware tap-to-click when the firmware
        /// switched them to absolute mode; `TouchTapRecognizer` restores it
        /// host-side by watching the same frame stream that drives scrolling.
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

        init(
            enabled: Bool? = nil,
            scale: Decimal? = nil,
            invert: Bool? = nil,
            axis: Axis? = nil,
            acceleration: Acceleration? = nil,
            tapToClick: TapToClick? = nil
        ) {
            self.enabled = enabled
            self.scale = scale
            self.invert = invert
            self.axis = axis
            self.acceleration = acceleration
            self.tapToClick = tapToClick
        }
    }
}

extension Configuration.TouchStream {
    static let scaleRange: ClosedRange<Double> = 0.001 ... 10.0
    static let defaultScale = 0.25

    var isEnabled: Bool {
        enabled ?? true
    }

    var resolvedScale: Double {
        (scale?.asTruncatedDouble ?? Self.defaultScale).clamped(to: Self.scaleRange)
    }

    var isInverted: Bool {
        invert ?? false
    }

    var resolvedAxis: Axis {
        axis ?? .y
    }

    var isTapToClickEnabled: Bool {
        tapToClick?.isEnabled ?? false
    }
}

extension Configuration.TouchStream.Acceleration {
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
}

extension Configuration.TouchStream.TapToClick {
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
}
