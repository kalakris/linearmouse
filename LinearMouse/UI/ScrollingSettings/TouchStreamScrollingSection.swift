// MIT License
// Copyright (c) 2021-2026 LinearMouse

import SwiftUI

extension ScrollingSettings {
    /// Control set for the "Raw Touch" scrolling mode (touch-stream
    /// scrolling from a supported keyboard trackpad).
    ///
    /// Touch-stream settings are direction-agnostic — the scroll axis comes
    /// from the pad's self-reported orientation — so the same controls appear
    /// on both the vertical and horizontal direction tabs and edit the same
    /// values. Scroll direction follows the system Natural Scrolling
    /// preference (like wheel devices); the generic "Reverse scrolling"
    /// toggle at the top of the pane flips that baseline, applied at the
    /// source as the engine's output sign.
    ///
    /// Only the everyday knobs are shown, matching the Smoothed pane's
    /// density; `acceleration.referenceSpeed`/`minGain`/`maxGain` and
    /// `momentum.startThreshold`/`maxSpeed` remain JSON-only expert
    /// settings.
    struct TouchStreamScrollingSection: View {
        @ObservedObject private var state = ScrollingSettingsState.shared

        /// The sliders cover the useful ranges; the text fields accept the
        /// full configuration ranges.
        private static let scaleSliderRange: ClosedRange<Double> = 0.01 ... 2.0
        private static let decaySliderRange: ClosedRange<Double> = 0.1 ... 3.0

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                sliderRow(
                    title: "Scroll speed",
                    description: "(0.001–10 points per touch count)",
                    value: $state.touchStreamScale,
                    range: Self.scaleSliderRange,
                    fieldRange: Scheme.Scrolling.TouchStream.scaleRange,
                    minimumValueLabel: "Slow",
                    maximumValueLabel: "Fast",
                    formatter: state.touchStreamScaleFormatter
                )

                sliderRow(
                    title: "Scroll acceleration",
                    description: "(0–2, 0 = off)",
                    value: $state.touchStreamAccelerationExponent,
                    range: Scheme.Scrolling.TouchStream.Acceleration.exponentRange,
                    minimumValueLabel: "Flat",
                    maximumValueLabel: "Adaptive",
                    formatter: state.touchStreamAccelerationExponentFormatter
                )

                sliderRow(
                    title: "Scroll inertia",
                    description: "(0.05–5 seconds)",
                    value: $state.touchStreamMomentumDecayTimeConstant,
                    range: Self.decaySliderRange,
                    fieldRange: Scheme.Scrolling.TouchStream.Momentum.decayTimeConstantRange,
                    minimumValueLabel: "Short",
                    maximumValueLabel: "Long",
                    formatter: state.touchStreamMomentumDecayTimeConstantFormatter
                )
            }
        }
    }
}
