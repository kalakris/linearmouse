// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

/// One absolute touch sample streamed by the keyboard's vendor-defined HID
/// collection.
///
/// Wire format (payload after the report ID; frames are carried in input
/// report `reportID` (0x04), which `TouchStreamManager` filters on before
/// parsing — the payload itself does not repeat it).
///
/// Protocol v3 (11 bytes):
///
///     byte 0: pad_id (0 = right pad; 1 = left pad, reserved)
///     byte 1: contact_id (0 on single-touch pads)
///     bytes 2-3: x, uint16 little-endian, absolute Cirque coordinate (~0-2047)
///     bytes 4-5: y, uint16 little-endian, absolute Cirque coordinate (~0-1535)
///     byte 6: z, uint8 touch strength (0 when not touched)
///     byte 7: flags: bit0 = touched, bit1 = scroll mode, bit2 = reserved
///     byte 8: seq, per-pad counter, +1 per emitted report, wraps
///     bytes 9-10: timestamp, uint16 little-endian, 100 µs units,
///                 wraps at 6.5536 s (device-side sample time)
///
/// Protocol v2 (legacy, 7 bytes — no contact_id/seq/timestamp):
///
///     byte 0: pad_id
///     bytes 1-2: x, uint16 little-endian
///     bytes 3-4: y, uint16 little-endian
///     byte 5: z
///     byte 6: flags: bit0 = touched, bit1 = scroll mode
///
/// Which layout applies is decided by the *validated feature report's*
/// protocol version (see `TouchStreamCapabilities`), defensively backed by
/// the frame length: a v3 device's frame that is too short for the v3 layout
/// but long enough for v2 is parsed as v2 rather than dropped.
///
/// Cadence: one report per sample while touched (~100 Hz), exactly one release
/// report (touched = 0) at lift-off, nothing while idle.
struct TouchStreamFrame: Equatable {
    /// HID input report ID carrying touch frames — a frozen protocol
    /// constant, deliberately the same ID as the capability feature report
    /// (`TouchStreamCapabilities.featureReportID`).
    static let reportID: UInt32 = 0x04

    static let v2PayloadLength = 7 // pad_id + x(2) + y(2) + z + flags
    static let v3PayloadLength = 11 // + contact_id, seq, timestamp(2)

    /// The wire payload length for a protocol version (v3 for any version
    /// newer than v2, since unknown versions never pass feature-report
    /// validation in the first place).
    static func payloadLength(forProtocolVersion version: Int) -> Int {
        version <= 2 ? v2PayloadLength : v3PayloadLength
    }

    var padID: UInt8

    /// v3: distinguishes fingers on multi-touch pads; 0 on single-touch
    /// hardware. Parsed as 0 for v2 frames (which predate the field).
    var contactID: UInt8

    var x: Int
    var y: Int
    var z: Int
    var touched: Bool
    var scrollMode: Bool

    /// v3: the per-pad wire sequence counter (+1 per emitted report, wraps).
    /// `nil` for v2 frames. Diagnostic only — silent drops are surfaced by
    /// `TouchStreamManager`'s gap logging.
    var seq: UInt8?

    /// v3: the raw device-side sample time in 100 µs ticks, wrapping at
    /// 6.5536 s. `nil` for v2 frames. `TouchStreamManager` unwraps this onto
    /// a continuous timeline (`TouchStreamDeviceClock`) and rewrites
    /// `timestamp` with it before the frame reaches the engine.
    var deviceTimestampTicks: UInt16?

    /// The engine-timeline timestamp. At parse time this is the host receive
    /// time (system uptime) captured in the HID report callback; for v3
    /// frames the manager replaces it with the reconstructed device-side
    /// sample time so velocity is immune to BLE connection-interval batching.
    var timestamp: TimeInterval

    /// Parses a report payload using the layout implied by
    /// `protocolVersion` (from the validated feature report). Returns `nil`
    /// for reports too short for even the v2 layout; extra trailing bytes
    /// (e.g. padding) are ignored.
    init?(reportBytes: [UInt8], protocolVersion: Int, timestamp: TimeInterval) {
        let wantsV3 = protocolVersion > 2

        // Defensive length fallback: a v3 device's frame shorter than the
        // v3 layout (but valid v2) parses as v2 instead of being dropped.
        let parseAsV3 = wantsV3 && reportBytes.count >= Self.v3PayloadLength

        guard reportBytes.count >= (parseAsV3 ? Self.v3PayloadLength : Self.v2PayloadLength) else {
            return nil
        }

        padID = reportBytes[0]

        if parseAsV3 {
            contactID = reportBytes[1]
            x = Int(reportBytes[2]) | (Int(reportBytes[3]) << 8)
            y = Int(reportBytes[4]) | (Int(reportBytes[5]) << 8)
            z = Int(reportBytes[6])
            touched = reportBytes[7] & 0x1 != 0
            scrollMode = reportBytes[7] & 0x2 != 0
            seq = reportBytes[8]
            deviceTimestampTicks = UInt16(reportBytes[9]) | (UInt16(reportBytes[10]) << 8)
        } else {
            contactID = 0
            x = Int(reportBytes[1]) | (Int(reportBytes[2]) << 8)
            y = Int(reportBytes[3]) | (Int(reportBytes[4]) << 8)
            z = Int(reportBytes[5])
            touched = reportBytes[6] & 0x1 != 0
            scrollMode = reportBytes[6] & 0x2 != 0
            seq = nil
            deviceTimestampTicks = nil
        }

        self.timestamp = timestamp
    }

    init(
        padID: UInt8 = 0,
        contactID: UInt8 = 0,
        x: Int = 0,
        y: Int = 0,
        z: Int = 0,
        touched: Bool,
        scrollMode: Bool,
        seq: UInt8? = nil,
        deviceTimestampTicks: UInt16? = nil,
        timestamp: TimeInterval
    ) {
        self.padID = padID
        self.contactID = contactID
        self.x = x
        self.y = y
        self.z = z
        self.touched = touched
        self.scrollMode = scrollMode
        self.seq = seq
        self.deviceTimestampTicks = deviceTimestampTicks
        self.timestamp = timestamp
    }
}
