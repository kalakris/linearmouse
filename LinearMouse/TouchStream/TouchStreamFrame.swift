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
/// This is the only layout: v2 support was dropped 2026-08-28 (v2 only ever
/// ran on the pre-release prototype firmware; the feature report — see
/// `TouchStreamCapabilities` — is the version authority and now validates
/// v3 alone). Frames shorter than the layout are malformed and rejected.
///
/// Cadence: one report per sample while touched (~100 Hz), exactly one release
/// report (touched = 0) at lift-off, nothing while idle.
struct TouchStreamFrame: Equatable {
    /// HID input report ID carrying touch frames — a frozen protocol
    /// constant, deliberately the same ID as the capability feature report
    /// (`TouchStreamCapabilities.featureReportID`).
    static let reportID: UInt32 = 0x04

    /// pad_id, contact_id, x(2), y(2), z, flags, seq, timestamp(2).
    static let payloadLength = 11

    var padID: UInt8

    /// Distinguishes fingers on multi-touch pads; 0 on single-touch
    /// hardware.
    var contactID: UInt8

    var x: Int
    var y: Int
    var z: Int
    var touched: Bool
    var scrollMode: Bool

    /// The per-pad wire sequence counter (+1 per emitted report, wraps).
    /// `nil` only on synthesized frames (e.g. the stale-touch release),
    /// which never cross the wire. Diagnostic only — silent drops are
    /// surfaced by `TouchStreamManager`'s gap logging.
    var seq: UInt8?

    /// The raw device-side sample time in 100 µs ticks, wrapping at
    /// 6.5536 s. `nil` only on synthesized frames. `TouchStreamManager`
    /// unwraps this onto a continuous timeline (`TouchStreamDeviceClock`)
    /// and rewrites `timestamp` with it before the frame reaches the
    /// engine.
    var deviceTimestampTicks: UInt16?

    /// The engine-timeline timestamp. At parse time this is the host receive
    /// time (system uptime) captured in the HID report callback; the manager
    /// replaces it with the reconstructed device-side sample time so
    /// velocity is immune to BLE connection-interval batching.
    var timestamp: TimeInterval

    /// Parses a report payload in place — no per-report heap allocation on
    /// the ~100 Hz HID-callback path. Parsing starts at `offset` (non-zero
    /// when the transport prepends the report ID byte). Returns `nil` for
    /// payloads too short for the layout; extra trailing bytes (e.g.
    /// padding) are ignored.
    init?(
        reportBytes: UnsafeRawBufferPointer,
        offset: Int = 0,
        timestamp: TimeInterval
    ) {
        guard reportBytes.count - offset >= Self.payloadLength else {
            return nil
        }

        func byte(_ index: Int) -> UInt8 {
            reportBytes[offset + index]
        }

        padID = byte(0)
        contactID = byte(1)
        x = Int(byte(2)) | (Int(byte(3)) << 8)
        y = Int(byte(4)) | (Int(byte(5)) << 8)
        z = Int(byte(6))
        touched = byte(7) & 0x1 != 0
        scrollMode = byte(7) & 0x2 != 0
        seq = byte(8)
        deviceTimestampTicks = UInt16(byte(9)) | (UInt16(byte(10)) << 8)
        self.timestamp = timestamp
    }

    /// Array-based convenience over the buffer parse, for callers that
    /// already hold a copied payload (e.g. test fixtures).
    init?(reportBytes: [UInt8], timestamp: TimeInterval) {
        guard let frame = reportBytes.withUnsafeBytes({
            TouchStreamFrame(reportBytes: $0, timestamp: timestamp)
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
