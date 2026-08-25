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
    /// values.
    struct TouchStreamScrollingSection: View {
        @ObservedObject private var state = ScrollingSettingsState.shared

        /// The sliders cover the useful ranges; the text fields accept the
        /// full configuration ranges.
        private static let scaleSliderRange: ClosedRange<Double> = 0.01 ... 2.0
        private static let referenceSpeedSliderRange: ClosedRange<Double> = 100 ... 3000
        private static let maxGainSliderRange: ClosedRange<Double> = 1.0 ... 8.0
        private static let decaySliderRange: ClosedRange<Double> = 0.1 ... 3.0
        private static let startThresholdSliderRange: ClosedRange<Double> = 0 ... 1000
        private static let maxSpeedSliderRange: ClosedRange<Double> = 500 ... 20000

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

                Toggle(isOn: $state.touchStreamInverted) {
                    withDescription {
                        Text("Invert scroll direction")
                        Text("Flip the scroll direction relative to the pad's native orientation.")
                    }
                }

                Toggle(isOn: $state.touchStreamAccelerationEnabled) {
                    withDescription {
                        Text("Scroll acceleration")
                        Text("Slow drags scroll precisely; fast flicks travel further.")
                    }
                }

                if state.touchStreamAccelerationEnabled {
                    sliderRow(
                        title: "Acceleration exponent",
                        description: "(0–2, 0 = linear)",
                        value: $state.touchStreamAccelerationExponent,
                        range: Scheme.Scrolling.TouchStream.Acceleration.exponentRange,
                        minimumValueLabel: "Flat",
                        maximumValueLabel: "Adaptive",
                        formatter: state.touchStreamAccelerationExponentFormatter
                    )

                    sliderRow(
                        title: "Reference speed",
                        description: "(50–20000 counts/s at gain 1)",
                        value: $state.touchStreamAccelerationReferenceSpeed,
                        range: Self.referenceSpeedSliderRange,
                        fieldRange: Scheme.Scrolling.TouchStream.Acceleration.referenceSpeedRange,
                        minimumValueLabel: "Slow",
                        maximumValueLabel: "Fast",
                        formatter: state.touchStreamAccelerationReferenceSpeedFormatter
                    )

                    sliderRow(
                        title: "Minimum gain",
                        description: "(0.05–1)",
                        value: $state.touchStreamAccelerationMinGain,
                        range: Scheme.Scrolling.TouchStream.Acceleration.minGainRange,
                        minimumValueLabel: "Reduced",
                        maximumValueLabel: "Full",
                        formatter: state.touchStreamAccelerationMinGainFormatter
                    )

                    sliderRow(
                        title: "Maximum gain",
                        description: "(1–20)",
                        value: $state.touchStreamAccelerationMaxGain,
                        range: Self.maxGainSliderRange,
                        fieldRange: Scheme.Scrolling.TouchStream.Acceleration.maxGainRange,
                        minimumValueLabel: "Full",
                        maximumValueLabel: "Amplified",
                        formatter: state.touchStreamAccelerationMaxGainFormatter
                    )
                }

                sliderRow(
                    title: "Momentum decay",
                    description: "(0.05–5 seconds)",
                    value: $state.touchStreamMomentumDecayTimeConstant,
                    range: Self.decaySliderRange,
                    fieldRange: Scheme.Scrolling.TouchStream.Momentum.decayTimeConstantRange,
                    minimumValueLabel: "Short",
                    maximumValueLabel: "Long",
                    formatter: state.touchStreamMomentumDecayTimeConstantFormatter
                )

                sliderRow(
                    title: "Momentum threshold",
                    description: "(0–5000 points/s)",
                    value: $state.touchStreamMomentumStartThreshold,
                    range: Self.startThresholdSliderRange,
                    fieldRange: Scheme.Scrolling.TouchStream.Momentum.startThresholdRange,
                    minimumValueLabel: "Eager",
                    maximumValueLabel: "Reluctant",
                    formatter: state.touchStreamMomentumStartThresholdFormatter
                )

                sliderRow(
                    title: "Momentum top speed",
                    description: "(100–50000 points/s)",
                    value: $state.touchStreamMomentumMaxSpeed,
                    range: Self.maxSpeedSliderRange,
                    fieldRange: Scheme.Scrolling.TouchStream.Momentum.maxSpeedRange,
                    minimumValueLabel: "Slow",
                    maximumValueLabel: "Fast",
                    formatter: state.touchStreamMomentumMaxSpeedFormatter
                )
            }
        }
    }
}
