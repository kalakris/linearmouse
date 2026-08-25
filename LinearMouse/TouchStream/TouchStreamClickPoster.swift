// MIT License
// Copyright (c) 2021-2026 LinearMouse

import CoreGraphics
import Foundation
import os.log

/// Posts `TouchTapRecognizer.Tap`s as synthetic left mouseDown + mouseUp
/// pairs at the tap's cursor location.
///
/// Events carry the tap's click state (so apps recognize double- and
/// triple-clicks), the current modifier flags (so shift-click and friends
/// work), and the `isLinearMouseSyntheticEvent` marker — the same generic
/// userData marker `ButtonMappingTransformer` puts on its synthetic button
/// events — so LinearMouse's own event tap never re-transforms them.
///
/// Must only be used from the event thread (the recognizer's owner already
/// runs there).
final class TouchStreamClickPoster {
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier!, category: "TouchStreamClick"
    )

    private let eventSink: (CGEvent) -> Void

    init(eventSink: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        self.eventSink = eventSink
    }

    func post(_ tap: TouchTapRecognizer.Tap) {
        guard
            let mouseDownEvent = makeClickEvent(tap, pressed: true),
            let mouseUpEvent = makeClickEvent(tap, pressed: false)
        else {
            return
        }

        eventSink(mouseDownEvent)
        eventSink(mouseUpEvent)

        os_log(
            "post touch-stream tap click clickState=%{public}lld",
            log: Self.log,
            type: .info,
            tap.clickState
        )
    }

    private func makeClickEvent(_ tap: TouchTapRecognizer.Tap, pressed: Bool) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: pressed ? .leftMouseDown : .leftMouseUp,
            mouseCursorPosition: tap.location,
            mouseButton: .left
        ) else {
            return nil
        }

        event.flags = ModifierState.normalize(ModifierState.shared.currentFlags)
        event.setIntegerValueField(.mouseEventClickState, value: tap.clickState)
        event.isLinearMouseSyntheticEvent = true
        return event
    }
}
