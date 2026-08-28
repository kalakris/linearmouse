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
/// protocol version (see `TouchStreamCapabilities`) — the feature report is
/// the version authority, so frames shorter than that version's layout are
/// malformed and rejected rather than second-guessed as the older layout.
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

    /// Parses a report payload in place — no per-report heap allocation on
    /// the ~100 Hz HID-callback path — using the layout implied by
    /// `protocolVersion` (from the validated feature report). Parsing starts
    /// at `offset` (non-zero when the transport prepends the report ID
    /// byte). Returns `nil` for payloads too short for that version's
    /// layout; extra trailing bytes (e.g. padding) are ignored.
    init?(
        reportBytes: UnsafeRawBufferPointer,
        offset: Int = 0,
        protocolVersion: Int,
        timestamp: TimeInterval
    ) {
        guard reportBytes.count - offset >= Self.payloadLength(forProtocolVersion: protocolVersion) else {
            return nil
        }

        func byte(_ index: Int) -> UInt8 {
            reportBytes[offset + index]
        }

        // v2 and v3 share the layout except for v3's leading contact_id
        // (which shifts everything after pad_id by one byte) and its
        // trailing seq/timestamp.
        let isV3 = protocolVersion > 2
        let o = isV3 ? 1 : 0

        padID = byte(0)
        contactID = isV3 ? byte(1) : 0
        x = Int(byte(1 + o)) | (Int(byte(2 + o)) << 8)
        y = Int(byte(3 + o)) | (Int(byte(4 + o)) << 8)
        z = Int(byte(5 + o))
        touched = byte(6 + o) & 0x1 != 0
        scrollMode = byte(6 + o) & 0x2 != 0
        seq = isV3 ? byte(7 + o) : nil
        deviceTimestampTicks = isV3 ? UInt16(byte(8 + o)) | (UInt16(byte(9 + o)) << 8) : nil
        self.timestamp = timestamp
    }

    /// Array-based convenience over the buffer parse, for callers that
    /// already hold a copied payload (e.g. test fixtures).
    init?(reportBytes: [UInt8], protocolVersion: Int, timestamp: TimeInterval) {
        guard let frame = reportBytes.withUnsafeBytes({
            TouchStreamFrame(reportBytes: $0, protocolVersion: protocolVersion, timestamp: timestamp)
        }) else {
            return nil
        }
        self = frame
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
