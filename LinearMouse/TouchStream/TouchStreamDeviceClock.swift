// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

/// Unwraps the touch stream's 16-bit device-side sample timestamps (100 µs
/// units, wrapping at 6.5536 s — the HID Scan Time convention) onto a
/// continuous timeline comparable with host system uptime.
///
/// Why: over BLE, frames sampled 10 ms apart arrive batched at the
/// connection interval, so arrival-time deltas oscillate between ~0 and a
/// multiple of the real sample interval — which distorts every velocity
/// derived from them (acceleration gain, momentum seed). The device
/// timestamp restores the true sample cadence; protocol v3's spec requires
/// hosts to derive finger velocity from it.
///
/// The reconstructed timeline is *anchored* to the host arrival time of the
/// first frame (and re-anchored after any discontinuity), then advanced by
/// exact device-side deltas. It therefore never leads host time by more than
/// clock drift, and lags it by at most the anchor frame's delivery latency —
/// close enough for the momentum machinery, whose per-tick dt is clamped
/// anyway. It is monotonic by construction.
struct TouchStreamDeviceClock {
    /// One device timestamp tick (100 µs), per the wire spec.
    static let tickDuration: TimeInterval = 100e-6

    /// Device- or arrival-time gaps larger than this are treated as a stream
    /// discontinuity and re-anchor the timeline instead of trusting the
    /// wrapped 16-bit delta. ~2 s: comfortably above any genuine
    /// intra-gesture gap (the stream runs at ~100 Hz while touched, and the
    /// stale-touch timeout fires at 150 ms), and well below the 6.5536 s
    /// wrap period, so a delta this large is ambiguous rather than
    /// informative. The arrival-time check catches silence longer than a
    /// full wrap period, which the 16-bit delta alone cannot see.
    static let discontinuityThreshold: TimeInterval = 2.0

    private var lastTicks: UInt16?
    private var lastArrival: TimeInterval = 0
    private var lastReconstructed: TimeInterval = 0

    /// Maps a device timestamp to the continuous timeline. `arrival` is the
    /// host receive time (system uptime) of the same frame, used to anchor
    /// the timeline and to detect discontinuities.
    mutating func reconstruct(ticks: UInt16, arrival: TimeInterval) -> TimeInterval {
        defer {
            lastTicks = ticks
            lastArrival = arrival
        }

        guard let lastTicks else {
            lastReconstructed = arrival
            return lastReconstructed
        }

        // Wrapping 16-bit delta: correct across the 6.5536 s wrap as long as
        // consecutive frames are less than one wrap period apart. A genuinely
        // out-of-order timestamp shows up as a huge delta and lands in the
        // discontinuity path below.
        let deltaTicks = ticks &- lastTicks
        let delta = TimeInterval(deltaTicks) * Self.tickDuration

        if delta > Self.discontinuityThreshold || arrival - lastArrival > Self.discontinuityThreshold {
            // Discontinuity/reset: re-anchor to arrival time, clamped to keep
            // the timeline monotonic.
            lastReconstructed = max(arrival, lastReconstructed)
        } else {
            lastReconstructed += delta
        }

        return lastReconstructed
    }

    /// Forgets the anchor; the next frame re-anchors to its arrival time.
    mutating func reset() {
        lastTicks = nil
        lastArrival = 0
        lastReconstructed = 0
    }
}
