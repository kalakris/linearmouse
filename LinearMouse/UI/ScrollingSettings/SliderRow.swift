// MIT License
// Copyright (c) 2021-2026 LinearMouse

import SwiftUI

/// A labeled slider paired with a deferred numeric entry field, as used by
/// the scrolling settings sections. The slider covers `range` (the useful
/// sub-range); the text field accepts `fieldRange` when given (the full
/// configuration range), falling back to `range`.
func sliderRow(
    title: LocalizedStringKey,
    description: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    fieldRange: ClosedRange<Double>? = nil,
    minimumValueLabel: LocalizedStringKey,
    maximumValueLabel: LocalizedStringKey,
    formatter: NumberFormatter
) -> some View {
    HStack(alignment: .firstTextBaseline) {
        Slider(
            value: value,
            in: range
        ) {
            labelWithDescription {
                Text(title)
                Text(verbatim: description)
            }
        } minimumValueLabel: {
            Text(minimumValueLabel)
        } maximumValueLabel: {
            Text(maximumValueLabel)
        }

        DeferredNumberField(
            value: value,
            formatter: formatter,
            range: fieldRange ?? range
        )
        .frame(width: 60, height: 22)
    }
}
