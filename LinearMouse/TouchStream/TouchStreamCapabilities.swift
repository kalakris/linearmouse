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
/// feature report (protocol v2).
///
/// Wire format (8-byte payload, same report ID 0x04 as the input report, read
/// with `IOHIDDeviceGetReport(kIOHIDReportTypeFeature)`):
///
///     byte 0: protocol version (2)
///     byte 1: pads-present bitmask (bit0 = right pad, bit1 = left pad)
///     byte 2: resolution in counts/mm (≈38; 0 = unknown)
///     byte 3: orientation bits mirroring the pad's devicetree props:
///             bit0 = rotate-90, bit1 = x-invert, bit2 = y-invert
///     bytes 4-5: x-max, uint16 little-endian
///     bytes 6-7: y-max, uint16 little-endian
///
/// A device whose feature report is absent, short, or reports an unsupported
/// version is treated as non-streaming.
struct TouchStreamCapabilities: Equatable {
    static let featureReportID: CFIndex = 0x04
    static let payloadLength = 8

    /// Protocol versions this build knows how to consume. Anything newer is
    /// treated as non-streaming rather than guessed at.
    static let supportedVersions: ClosedRange<Int> = 1 ... 2

    var version: Int
    var padsPresent: UInt8
    /// Pad resolution in counts/mm; 0 = unknown.
    var countsPerMM: Int
    var rotate90: Bool
    var invertX: Bool
    var invertY: Bool
    var xMax: Int
    var yMax: Int

    init?(reportBytes: [UInt8]) {
        guard reportBytes.count >= Self.payloadLength else {
            return nil
        }

        version = Int(reportBytes[0])
        padsPresent = reportBytes[1]
        countsPerMM = Int(reportBytes[2])
        rotate90 = reportBytes[3] & 0x1 != 0
        invertX = reportBytes[3] & 0x2 != 0
        invertY = reportBytes[3] & 0x4 != 0
        xMax = Int(reportBytes[4]) | (Int(reportBytes[5]) << 8)
        yMax = Int(reportBytes[6]) | (Int(reportBytes[7]) << 8)
    }

    init(
        version: Int = 2,
        padsPresent: UInt8 = 0x1,
        countsPerMM: Int = 38,
        rotate90: Bool = false,
        invertX: Bool = false,
        invertY: Bool = false,
        xMax: Int = 2047,
        yMax: Int = 1535
    ) {
        self.version = version
        self.padsPresent = padsPresent
        self.countsPerMM = countsPerMM
        self.rotate90 = rotate90
        self.invertX = invertX
        self.invertY = invertY
        self.xMax = xMax
        self.yMax = yMax
    }

    var isSupported: Bool {
        Self.supportedVersions.contains(version)
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

    /// The engine `invert` flag that produces the pad's natural scroll
    /// direction (engine convention: `invert == false` means a finger moving
    /// toward an increasing raw coordinate produces positive, scroll-up
    /// deltas).
    ///
    /// Derivation, anchored on the Go60 ground truth: logical Y (post-swap,
    /// post-invert) is `iY * raw` where `iY = invertY ? -1 : +1`, and the
    /// natural direction maps decreasing logical Y (finger moving "up") to
    /// positive deltas, i.e. `deltaY ∝ -iY * Δraw`. Hence the engine sign is
    /// `-iY`, which means `invert == !invertY`. For the Go60
    /// (rotate-90 + y-invert) this yields axis = .x, invert = false —
    /// exactly the user-validated prototype configuration
    /// `{axis: "x", invert: false}`. Pinned by
    /// `TouchStreamCapabilitiesTests.testGo60OrientationAnchor`.
    var naturalScrollInverted: Bool {
        !invertY
    }

    /// The engine `invert` flag after applying the user-facing direction
    /// override on top of the orientation-derived natural direction.
    func scrollInverted(for direction: Scheme.Scrolling.TouchStream.Direction) -> Bool {
        naturalScrollInverted != (direction == .inverted)
    }
}
