// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation

/// The raw Cirque coordinate that feeds the scroll engine's position and
/// velocity math.
enum TouchStreamAxis: Equatable {
    case x
    case y
}

/// Capabilities self-reported by a streaming device through the touch-stream
/// feature report (protocol v3, same report ID 0x04 as the input report,
/// read with `IOHIDDeviceGetReport(kIOHIDReportTypeFeature)`).
///
/// v3 wire format (20-byte payload):
///
///     byte 0: protocol version (3)
///     byte 1: pads-present bitmask (bit N = pad_id N)
///     byte 2: capabilities (bit0 reserved for the mode gate; rest 0)
///     byte 3: reserved (0)
///     bytes 4-11: pad slot 0
///     bytes 12-19: pad slot 1
///
/// Slots describe *present* pads in ascending pad_id order. Each 8-byte slot:
///
///     +0: resolution in counts/mm (≈38; 0 = unknown)
///     +1: orientation bits mirroring the pad's devicetree props:
///         bit0 = rotate-90, bit1 = x-invert, bit2 = y-invert
///     +2-3: x-max, uint16 little-endian
///     +4-5: y-max, uint16 little-endian
///     +6: max contacts (1 on a Pinnacle)
///     +7: reserved (0)
///
/// A device whose feature report is absent, short, or reports an unsupported
/// version is treated as non-streaming. (Legacy v2 support was dropped
/// 2026-08-28: v2 only ever ran on the pre-release prototype firmware, so
/// the v0-prototype rollback binaries now get wheel-fallback scrolling
/// only.)
struct TouchStreamCapabilities: Equatable {
    static let featureReportID: CFIndex = 0x04
    static let payloadLength = 20

    /// The protocol versions this build knows how to consume. Anything
    /// else — older (v2 is dropped, v1 never existed) or newer — is treated
    /// as non-streaming rather than guessed at.
    static let supportedVersions: ClosedRange<Int> = 3 ... 3

    /// Per-pad geometry and orientation (one pad slot).
    struct Pad: Equatable {
        /// Pad resolution in counts/mm; 0 = unknown.
        var countsPerMM: Int
        var rotate90: Bool
        var invertX: Bool
        var invertY: Bool
        var xMax: Int
        var yMax: Int
        /// Maximum simultaneous contacts (1 on a Pinnacle).
        var maxContacts: Int

        init(
            countsPerMM: Int = 38,
            rotate90: Bool = false,
            invertX: Bool = false,
            invertY: Bool = false,
            xMax: Int = 2047,
            yMax: Int = 1535,
            maxContacts: Int = 1
        ) {
            self.countsPerMM = countsPerMM
            self.rotate90 = rotate90
            self.invertX = invertX
            self.invertY = invertY
            self.xMax = xMax
            self.yMax = yMax
            self.maxContacts = maxContacts
        }

        /// Parses an 8-byte pad slot.
        init(slotBytes: ArraySlice<UInt8>) {
            let bytes = Array(slotBytes)
            countsPerMM = Int(bytes[0])
            rotate90 = bytes[1] & 0x1 != 0
            invertX = bytes[1] & 0x2 != 0
            invertY = bytes[1] & 0x4 != 0
            xMax = Int(bytes[2]) | (Int(bytes[3]) << 8)
            yMax = Int(bytes[4]) | (Int(bytes[5]) << 8)
            maxContacts = bytes.count > 6 ? max(1, Int(bytes[6])) : 1
        }
    }

    var version: Int
    var padsPresent: UInt8
    /// Capabilities byte (bit0 reserved for the mode gate).
    var capabilityBits: UInt8
    /// Per-pad capabilities keyed by pad_id, one entry per bit set in
    /// `padsPresent`.
    var pads: [UInt8: Pad]

    init?(reportBytes: [UInt8]) {
        guard let version = reportBytes.first.map(Int.init),
              Self.supportedVersions.contains(version) else {
            // Unknown versions are rejected outright — later layouts are
            // not guessed at.
            return nil
        }

        guard reportBytes.count >= Self.payloadLength else {
            return nil
        }

        self.version = version
        padsPresent = reportBytes[1]
        capabilityBits = reportBytes[2]

        var pads: [UInt8: Pad] = [:]
        // Slots describe present pads in ascending pad_id order.
        var slotOffset = 4
        for padID in Self.presentPadIDs(padsPresent) {
            guard slotOffset + 8 <= reportBytes.count else {
                break // more pads advertised than slots carried
            }
            pads[padID] = Pad(slotBytes: reportBytes[slotOffset ..< slotOffset + 8])
            slotOffset += 8
        }
        self.pads = pads
    }

    init(
        version: Int = 3,
        padsPresent: UInt8 = 0x1,
        capabilityBits: UInt8 = 0,
        countsPerMM: Int = 38,
        rotate90: Bool = false,
        invertX: Bool = false,
        invertY: Bool = false,
        xMax: Int = 2047,
        yMax: Int = 1535
    ) {
        self.version = version
        self.padsPresent = padsPresent
        self.capabilityBits = capabilityBits

        let pad = Pad(
            countsPerMM: countsPerMM,
            rotate90: rotate90,
            invertX: invertX,
            invertY: invertY,
            xMax: xMax,
            yMax: yMax
        )
        var pads: [UInt8: Pad] = [:]
        for padID in Self.presentPadIDs(padsPresent) {
            pads[padID] = pad
        }
        self.pads = pads
    }

    /// The pad_ids set in a pads-present bitmask, in ascending order.
    private static func presentPadIDs(_ padsPresent: UInt8) -> [UInt8] {
        ((0 as UInt8) ..< 8).filter { padsPresent & (1 << $0) != 0 }
    }

    var isSupported: Bool {
        Self.supportedVersions.contains(version) && !pads.isEmpty
    }

    /// The pad whose geometry and orientation configure the scroll engine
    /// (pad_id 0, the right pad; both pads share one engine config), falling
    /// back to the lowest present pad. Only nil for a degenerate empty
    /// report (rejected by `isSupported`).
    var primaryPad: Pad? {
        pads[0] ?? pads.min { $0.key < $1.key }?.value
    }

    /// Primary-pad conveniences, keeping single-pad call sites (engine
    /// configuration, logging, tests) version-agnostic.
    var countsPerMM: Int {
        primaryPad?.countsPerMM ?? 0
    }

    var rotate90: Bool {
        primaryPad?.rotate90 ?? false
    }

    var invertX: Bool {
        primaryPad?.invertX ?? false
    }

    var invertY: Bool {
        primaryPad?.invertY ?? false
    }

    var xMax: Int {
        primaryPad?.xMax ?? 0
    }

    var yMax: Int {
        primaryPad?.yMax ?? 0
    }

    /// Parses a feature-report buffer into supported capabilities, tolerating
    /// transports that prepend the report ID byte. Returns `nil` for short
    /// buffers and unsupported protocol versions alike — either way the
    /// device is treated as non-streaming.
    static func parse(reportBytes: [UInt8]) -> TouchStreamCapabilities? {
        if let capabilities = TouchStreamCapabilities(reportBytes: reportBytes), capabilities.isSupported {
            return capabilities
        }

        // Defensive: some transports have been observed to prepend the report
        // ID byte (the version byte can never be 0x04, so this is
        // unambiguous).
        if reportBytes.first == UInt8(featureReportID),
           let capabilities = TouchStreamCapabilities(reportBytes: Array(reportBytes.dropFirst())),
           capabilities.isSupported {
            return capabilities
        }

        return nil
    }
}

extension TouchStreamCapabilities {
    /// The raw coordinate that carries logical-vertical finger motion.
    ///
    /// The orientation bits mirror the pad's devicetree props, whose
    /// convention (ZMK's `zmk,input-processor-transform`) is: `rotate-90`
    /// swaps the raw axes first, then `x-invert`/`y-invert` negate the
    /// post-swap logical axes. So with `rotate-90` set, logical Y rides the
    /// raw X coordinate.
    var scrollAxis: TouchStreamAxis {
        rotate90 ? .x : .y
    }

    /// The device-orientation part of the engine `invert` sign (engine
    /// convention: `invert == false` means a finger moving toward an
    /// increasing raw coordinate produces positive, scroll-up deltas).
    ///
    /// This value alone yields the pad's *old-school* ("wheel-like")
    /// direction: a finger moving up scrolls the view up, i.e. content moves
    /// opposite the finger. Derivation, anchored on the Go60 ground truth:
    /// logical Y (post-swap, post-invert) is `iY * raw` where
    /// `iY = invertY ? -1 : +1`, and the old-school direction maps decreasing
    /// logical Y (finger moving "up") to positive deltas, i.e.
    /// `deltaY ∝ -iY * Δraw`. Hence the engine sign is `-iY`, which means
    /// `invert == !invertY`. For the Go60 (rotate-90 + y-invert) this yields
    /// axis = .x, invert = false — exactly the user-validated prototype
    /// configuration `{axis: "x", invert: false}` (validated on a system with
    /// Natural Scrolling off). Pinned by
    /// `TouchStreamCapabilitiesTests.testGo60DirectionTruthTable`.
    var orientationScrollInverted: Bool {
        !invertY
    }

    /// The engine `invert` flag after layering the macOS Natural Scrolling
    /// preference and the scheme's generic `scrolling.reverse` (vertical)
    /// toggle on top of the orientation-derived old-school baseline.
    ///
    /// For wheel devices macOS applies the system-wide Natural Scrolling
    /// preference upstream of LinearMouse's event tap, so "Reverse scrolling"
    /// off means "follow the system preference". The touch-stream pipeline
    /// synthesizes events downstream of that preference, so it must apply the
    /// same convention itself for the toggle to mean the same thing in every
    /// mode:
    ///
    /// - system natural ON,  reverse OFF → content follows the fingers
    ///   (phone-style)
    /// - system natural OFF, reverse OFF → old-school (content moves opposite
    ///   the fingers)
    /// - reverse ON flips either.
    ///
    /// This is the single point where either preference enters the
    /// touch-stream pipeline — the event-tap `ReverseScrollingTransformer`
    /// skips LinearMouse's synthetic events and the system preference never
    /// touches posted events, so no flip is ever applied twice.
    func scrollInverted(systemPrefersNatural: Bool, reversed: Bool) -> Bool {
        (orientationScrollInverted != systemPrefersNatural) != reversed
    }
}
