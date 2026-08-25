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
        /// Whether touch-stream scrolling is active. Defaults to `true` when
        /// the `touchStream` object is present; the feature is entirely off
        /// when the object is absent.
        var enabled: Bool?

        /// Scroll scale in screen points per Cirque touch count.
        var scale: Decimal?

        /// Inverts the scroll direction. With `invert` unset or `false`, a
        /// finger moving toward increasing Cirque Y produces positive
        /// (scroll-up) deltas.
        var invert: Bool?

        init(enabled: Bool? = nil, scale: Decimal? = nil, invert: Bool? = nil) {
            self.enabled = enabled
            self.scale = scale
            self.invert = invert
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
}
