// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation
@testable import LinearMouse

// Shared `TouchStreamFrame` factories for the touch-stream tests,
// modeling a ~100 Hz Cirque frame stream.

func scrollFrame(x: Int = 1000, y: Int = 500, at timestamp: TimeInterval, pad: UInt8 = 0) -> TouchStreamFrame {
    .init(padID: pad, x: x, y: y, z: 40, touched: true, scrollMode: true, timestamp: timestamp)
}

func pointerFrame(x: Int = 1000, y: Int = 500, at timestamp: TimeInterval, pad: UInt8 = 0) -> TouchStreamFrame {
    .init(padID: pad, x: x, y: y, z: 40, touched: true, scrollMode: false, timestamp: timestamp)
}

func releaseFrame(at timestamp: TimeInterval, scrollMode: Bool) -> TouchStreamFrame {
    .init(touched: false, scrollMode: scrollMode, timestamp: timestamp)
}

// MARK: - Raw wire payloads

/// A raw v3 input-report payload (11 bytes: pad, contact, x LE, y LE, z,
/// flags, seq, timestamp LE in 100 µs ticks).
func v3FrameBytes(
    pad: UInt8 = 0,
    contact: UInt8 = 0,
    x: UInt16 = 1000,
    y: UInt16 = 500,
    z: UInt8 = 40,
    flags: UInt8 = 0b11, // touched + scroll mode
    seq: UInt8 = 0,
    timestampTicks: UInt16 = 0
) -> [UInt8] {
    [
        pad,
        contact,
        UInt8(x & 0xFF), UInt8(x >> 8),
        UInt8(y & 0xFF), UInt8(y >> 8),
        z,
        flags,
        seq,
        UInt8(timestampTicks & 0xFF), UInt8(timestampTicks >> 8)
    ]
}
