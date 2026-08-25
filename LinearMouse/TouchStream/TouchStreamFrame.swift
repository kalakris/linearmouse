// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

/// One absolute touch sample streamed by the keyboard's vendor-defined HID
/// collection.
///
/// Wire format (payload after the report ID; frames are carried in input
/// report `reportID` (0x04), which `TouchStreamManager` filters on before
/// parsing — the payload itself does not repeat it):
///
///     byte 0: pad_id (0 = right pad; 1 = left pad, reserved)
///     bytes 1-2: x, uint16 little-endian, absolute Cirque coordinate (~0-2047)
///     bytes 3-4: y, uint16 little-endian, absolute Cirque coordinate (~0-1535)
///     byte 5: z, uint8 touch strength (0 when not touched)
///     byte 6: flags: bit0 = touched, bit1 = scroll mode
///
/// Cadence: one report per sample while touched (~100 Hz), exactly one release
/// report (touched = 0) at lift-off, nothing while idle.
struct TouchStreamFrame: Equatable {
    /// HID input report ID carrying touch frames — a frozen protocol
    /// constant, deliberately the same ID as the capability feature report
    /// (`TouchStreamCapabilities.featureReportID`).
    static let reportID: UInt32 = 0x04

    static let payloadLength = 7 // pad_id + x(2) + y(2) + z + flags

    var padID: UInt8
    var x: Int
    var y: Int
    var z: Int
    var touched: Bool
    var scrollMode: Bool

    /// Host receive time (system uptime), captured in the HID report callback.
    /// The device does not timestamp frames.
    var timestamp: TimeInterval

    /// Parses a report payload. Returns `nil` for short reports; extra
    /// trailing bytes (e.g. padding) are ignored.
    init?(reportBytes: [UInt8], timestamp: TimeInterval) {
        guard reportBytes.count >= Self.payloadLength else {
            return nil
        }

        padID = reportBytes[0]
        x = Int(reportBytes[1]) | (Int(reportBytes[2]) << 8)
        y = Int(reportBytes[3]) | (Int(reportBytes[4]) << 8)
        z = Int(reportBytes[5])
        touched = reportBytes[6] & 0x1 != 0
        scrollMode = reportBytes[6] & 0x2 != 0
        self.timestamp = timestamp
    }

    init(
        padID: UInt8 = 0,
        x: Int = 0,
        y: Int = 0,
        z: Int = 0,
        touched: Bool,
        scrollMode: Bool,
        timestamp: TimeInterval
    ) {
        self.padID = padID
        self.x = x
        self.y = y
        self.z = z
        self.touched = touched
        self.scrollMode = scrollMode
        self.timestamp = timestamp
    }
}
