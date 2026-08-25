// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import CoreGraphics
import Foundation

/// Recognizes taps in pointer-context touch frames (`TouchStreamFrame`) and
/// reports them so the owner can post synthetic left clicks.
///
/// The Cirque pads lost their hardware tap-to-click when the firmware switched
/// them to absolute mode; this restores the gesture host-side. Like
/// `TouchScrollEngine`, the recognizer is a pure per-frame state machine with
/// no I/O of its own: `handle(frame:)` is called for every parsed frame and
/// returns a `Tap` on a qualifying lift-off. The two side-effecting inputs it
/// needs — the system double-click interval and the current cursor location —
/// are injected so tests can drive it deterministically.
///
/// A tap is a touch-down → lift-off sequence where:
/// - the total duration is at most `Config.maxDuration`;
/// - the total movement (the larger of |Δx| and |Δy| from the touch-down
///   point, in raw Cirque counts) is at most `Config.maxMovementCounts`;
/// - no frame in the sequence — including the release frame — had the
///   scroll-mode flag set. A sequence that ever saw scroll mode never clicks,
///   which keeps the scroll engine's momentum-catch gesture from clicking.
///
/// Consecutive qualifying taps close together in time and cursor position
/// escalate `Tap.clickState` (1 → 2 → 3, then back to 1), which is what makes
/// apps recognize double- and triple-clicks.
final class TouchTapRecognizer {
    struct Config: Equatable {
        /// Maximum touch-down → lift-off duration for a tap.
        var maxDuration: TimeInterval = Configuration.TouchStream.TapToClick.defaultMaxDurationMs / 1000

        /// Maximum movement (max of |Δx|, |Δy| from the touch-down point) in
        /// raw Cirque counts.
        var maxMovementCounts = Configuration.TouchStream.TapToClick.defaultMaxMovement
    }

    /// A qualifying tap: the owner should post a left mouseDown + mouseUp at
    /// `location` carrying `clickState` in `.mouseEventClickState`.
    struct Tap: Equatable {
        var clickState: Int64
        var location: CGPoint
    }

    // MARK: - Tuning constants

    /// Consecutive taps whose cursor locations differ by more than this many
    /// screen points do not chain into a multi-click.
    private static let maxClickChainDriftPoints = 5.0

    /// Click state cycles 1 → 2 → 3 and then wraps back to 1.
    private static let maxClickState: Int64 = 3

    /// The pad taps are recognized for; pad_id 1 (left pad) is reserved by
    /// the protocol and ignored, mirroring `TouchScrollEngine`.
    private static let tapPadID: UInt8 = 0

    // MARK: - State

    var config: Config

    private let doubleClickInterval: () -> TimeInterval
    private let cursorLocation: () -> CGPoint?

    private struct Touch {
        var startTimestamp: TimeInterval
        var startX: Int
        var startY: Int
        var maxMovementCounts = 0.0
        var sawScrollMode: Bool
    }

    private var touch: Touch?
    private var lastTap: (timestamp: TimeInterval, location: CGPoint, clickState: Int64)?

    init(
        config: Config = .init(),
        doubleClickInterval: @escaping () -> TimeInterval = { NSEvent.doubleClickInterval },
        cursorLocation: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location }
    ) {
        self.config = config
        self.doubleClickInterval = doubleClickInterval
        self.cursorLocation = cursorLocation
    }

    // MARK: - Frame input

    func handle(frame: TouchStreamFrame) -> Tap? {
        guard frame.padID == Self.tapPadID else {
            return nil
        }

        guard frame.touched else {
            return handleRelease(frame: frame)
        }

        guard var activeTouch = touch else {
            touch = Touch(
                startTimestamp: frame.timestamp,
                startX: frame.x,
                startY: frame.y,
                sawScrollMode: frame.scrollMode
            )
            return nil
        }

        activeTouch.sawScrollMode = activeTouch.sawScrollMode || frame.scrollMode
        activeTouch.maxMovementCounts = max(
            activeTouch.maxMovementCounts,
            Double(abs(frame.x - activeTouch.startX)),
            Double(abs(frame.y - activeTouch.startY))
        )
        touch = activeTouch

        return nil
    }

    /// Drops any touch in progress (device disconnected, feature disabled).
    /// The multi-click chain survives — a reconnect between taps should not
    /// break a double-click any more than it has to.
    func reset() {
        touch = nil
    }

    private func handleRelease(frame: TouchStreamFrame) -> Tap? {
        guard let touch else {
            // A stray release without a tracked touch carries no information.
            return nil
        }
        self.touch = nil

        // Do not trust x/y on the release report — only the flags and the
        // timestamp matter.
        let duration = frame.timestamp - touch.startTimestamp
        guard !touch.sawScrollMode,
              !frame.scrollMode,
              duration <= config.maxDuration,
              touch.maxMovementCounts <= config.maxMovementCounts else {
            return nil
        }

        guard let location = cursorLocation() else {
            return nil
        }

        var clickState: Int64 = 1
        if let lastTap,
           frame.timestamp - lastTap.timestamp <= doubleClickInterval(),
           hypot(location.x - lastTap.location.x, location.y - lastTap.location.y)
           <= Self.maxClickChainDriftPoints,
           lastTap.clickState < Self.maxClickState {
            clickState = lastTap.clickState + 1
        }
        lastTap = (timestamp: frame.timestamp, location: location, clickState: clickState)

        return Tap(clickState: clickState, location: location)
    }
}
