// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation
@testable import LinearMouse

/// Shared `TouchStreamFrame` factories for the touch-stream tests,
/// modeling a ~100 Hz Cirque frame stream.

func scrollFrame(x: Int = 1000, y: Int = 500, at timestamp: TimeInterval, pad: UInt8 = 0) -> TouchStreamFrame {
    .init(padID: pad, x: x, y: y, z: 40, touched: true, scrollMode: true, timestamp: timestamp)
}

func pointerFrame(x: Int = 1000, y: Int = 500, at timestamp: TimeInterval, pad: UInt8 = 0) -> TouchStreamFrame {
    .init(padID: pad, x: x, y: y, z: 40, touched: true, scrollMode: false, timestamp: timestamp)
}

func releaseFrame(at timestamp: TimeInterval, scrollMode: Bool) -> TouchStreamFrame {
    .init(touched: false, scrollMode: scrollMode, timestamp: timestamp)
}
