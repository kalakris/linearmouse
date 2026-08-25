// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class TouchStreamCapabilitiesTests: XCTestCase {
    /// The Go60's actual feature report: protocol v2, right pad present,
    /// 38 counts/mm, rotate-90 + y-invert, 2047x1535.
    private static let go60Report: [UInt8] = [
        0x02, // version
        0x01, // pads present: right pad
        0x26, // 38 counts/mm
        0x05, // orientation: bit0 rotate-90, bit2 y-invert
        0xFF, 0x07, // x-max 2047
        0xFF, 0x05 // y-max 1535
    ]

    // MARK: - Parsing

    func testParsesGo60FeatureReport() {
        guard let capabilities = TouchStreamCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        XCTAssertEqual(capabilities.version, 2)
        XCTAssertEqual(capabilities.padsPresent, 0x01)
        XCTAssertEqual(capabilities.countsPerMM, 38)
        XCTAssertTrue(capabilities.rotate90)
        XCTAssertFalse(capabilities.invertX)
        XCTAssertTrue(capabilities.invertY)
        XCTAssertEqual(capabilities.xMax, 2047)
        XCTAssertEqual(capabilities.yMax, 1535)
        XCTAssertTrue(capabilities.isSupported)
    }

    func testParsesOrientationBitsIndividually() {
        var report = Self.go60Report

        report[3] = 0x00
        let plain = TouchStreamCapabilities.parse(reportBytes: report)
        XCTAssertEqual(plain?.rotate90, false)
        XCTAssertEqual(plain?.invertX, false)
        XCTAssertEqual(plain?.invertY, false)

        report[3] = 0x02
        let invertedX = TouchStreamCapabilities.parse(reportBytes: report)
        XCTAssertEqual(invertedX?.rotate90, false)
        XCTAssertEqual(invertedX?.invertX, true)
        XCTAssertEqual(invertedX?.invertY, false)

        report[3] = 0x07
        let all = TouchStreamCapabilities.parse(reportBytes: report)
        XCTAssertEqual(all?.rotate90, true)
        XCTAssertEqual(all?.invertX, true)
        XCTAssertEqual(all?.invertY, true)
    }

    func testRejectsShortReports() {
        XCTAssertNil(TouchStreamCapabilities.parse(reportBytes: []))
        XCTAssertNil(TouchStreamCapabilities.parse(reportBytes: [0x02]))
        XCTAssertNil(TouchStreamCapabilities.parse(reportBytes: Array(Self.go60Report.dropLast())))
    }

    func testRejectsUnsupportedVersions() {
        var report = Self.go60Report

        report[0] = 0x00
        XCTAssertNil(TouchStreamCapabilities.parse(reportBytes: report))

        // No v1 feature report ever existed: the feature report itself is
        // the v2 addition.
        report[0] = 0x01
        XCTAssertNil(TouchStreamCapabilities.parse(reportBytes: report))

        report[0] = 0x03
        XCTAssertNil(TouchStreamCapabilities.parse(reportBytes: report))

        report[0] = 0xFF
        XCTAssertNil(TouchStreamCapabilities.parse(reportBytes: report))
    }

    func testStripsPrependedReportID() {
        let prefixed = [UInt8(0x04)] + Self.go60Report
        let capabilities = TouchStreamCapabilities.parse(reportBytes: prefixed)
        XCTAssertEqual(capabilities?.version, 2)
        XCTAssertEqual(capabilities?.xMax, 2047)
        XCTAssertEqual(capabilities?.invertY, true)
    }

    func testIgnoresTrailingPadding() {
        let padded = Self.go60Report + [0x00, 0x00]
        XCTAssertEqual(TouchStreamCapabilities.parse(reportBytes: padded)?.yMax, 1535)
    }

    // MARK: - Orientation → axis/direction derivation

    /// GROUND TRUTH TRUTH TABLE: for the Go60's orientation (rotate-90 +
    /// y-invert), the engine sign for every combination of the system
    /// Natural Scrolling preference and the scheme's "Reverse scrolling"
    /// toggle. The (system natural OFF, reverse OFF) row MUST exactly
    /// reproduce the user-validated prototype behavior — what the old manual
    /// configuration `{axis: "x", invert: false}` produced on a system with
    /// Natural Scrolling off (old-school: content moves opposite the
    /// fingers). If a row fails, the scroll direction or axis has silently
    /// flipped — do not "fix" the test; fix the derivation.
    func testGo60DirectionTruthTable() {
        guard let capabilities = TouchStreamCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        XCTAssertEqual(capabilities.scrollAxis, .x)
        XCTAssertFalse(capabilities.orientationScrollInverted)

        // system natural OFF, reverse OFF → old-school (the v1-validated
        // direction).
        XCTAssertFalse(capabilities.scrollInverted(systemPrefersNatural: false, reversed: false))
        // system natural OFF, reverse ON → phone-style.
        XCTAssertTrue(capabilities.scrollInverted(systemPrefersNatural: false, reversed: true))
        // system natural ON, reverse OFF → content follows the fingers
        // (phone-style), matching what wheel devices do under the system
        // preference.
        XCTAssertTrue(capabilities.scrollInverted(systemPrefersNatural: true, reversed: false))
        // system natural ON, reverse ON → flipped back to old-school.
        XCTAssertFalse(capabilities.scrollInverted(systemPrefersNatural: true, reversed: true))
    }

    /// End-to-end anchor: an engine configured from the Go60 capabilities
    /// with Natural Scrolling off and `scrolling.reverse` unset must produce
    /// the exact deltas of the validated prototype configuration
    /// `{axis: "x", invert: false, scale: 0.25}` — a finger moving toward
    /// increasing raw X produces positive (scroll-up) deltas scaled by
    /// pointsPerCount, and raw Y movement is ignored.
    func testGo60OrientationAnchorDrivesEngineLikeTheValidatedConfig() {
        guard let capabilities = TouchStreamCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        let engine = TouchScrollEngine(config: .init(
            pointsPerCount: 0.25,
            invert: capabilities.scrollInverted(systemPrefersNatural: false, reversed: false),
            axis: capabilities.scrollAxis
        ))

        _ = engine.handle(frame: .init(x: 1000, y: 700, touched: true, scrollMode: true, timestamp: 0))
        let events = engine.handle(frame: .init(x: 1030, y: 400, touched: true, scrollMode: true, timestamp: 0.01))

        // +30 raw X counts * 0.25 points/count = +7.5, regardless of raw Y.
        XCTAssertEqual(events, [.touchChanged(deltaY: 7.5)])
    }

    /// The generic "Reverse scrolling" toggle (`scrolling.reverse.vertical`)
    /// flips the baseline: with it set (system preference unchanged), the
    /// same finger motion produces the exactly negated deltas of the anchor.
    func testReverseScrollingFlipsTheAnchorBehavior() {
        guard let capabilities = TouchStreamCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        let engine = TouchScrollEngine(config: .init(
            pointsPerCount: 0.25,
            invert: capabilities.scrollInverted(systemPrefersNatural: false, reversed: true),
            axis: capabilities.scrollAxis
        ))

        _ = engine.handle(frame: .init(x: 1000, y: 700, touched: true, scrollMode: true, timestamp: 0))
        let events = engine.handle(frame: .init(x: 1030, y: 400, touched: true, scrollMode: true, timestamp: 0.01))

        XCTAssertEqual(events, [.touchChanged(deltaY: -7.5)])
    }

    /// Enabling the system Natural Scrolling preference (reverse toggle
    /// unchanged) produces the same flip: content follows the fingers, so
    /// the anchor motion's deltas come out negated.
    func testSystemNaturalScrollingFlipsTheAnchorBehavior() {
        guard let capabilities = TouchStreamCapabilities.parse(reportBytes: Self.go60Report) else {
            XCTFail("Expected the Go60 feature report to parse")
            return
        }

        let engine = TouchScrollEngine(config: .init(
            pointsPerCount: 0.25,
            invert: capabilities.scrollInverted(systemPrefersNatural: true, reversed: false),
            axis: capabilities.scrollAxis
        ))

        _ = engine.handle(frame: .init(x: 1000, y: 700, touched: true, scrollMode: true, timestamp: 0))
        let events = engine.handle(frame: .init(x: 1030, y: 400, touched: true, scrollMode: true, timestamp: 0.01))

        XCTAssertEqual(events, [.touchChanged(deltaY: -7.5)])
    }

    /// The general derivation: rotate-90 moves logical-vertical motion onto
    /// the raw X axis; the old-school engine sign is `-1` unless y-invert
    /// flips it back (`invert == !invertY`), because the devicetree
    /// convention (ZMK input transforms) swaps axes first and then inverts
    /// the post-swap logical axes. The full engine sign layers the system
    /// Natural Scrolling preference and the reverse toggle on top as XORs.
    func testOrientationDerivationTable() {
        func derive(rotate90: Bool, invertY: Bool) -> (axis: TouchStreamAxis, inverted: Bool) {
            let capabilities = TouchStreamCapabilities(rotate90: rotate90, invertY: invertY)
            return (capabilities.scrollAxis, capabilities.orientationScrollInverted)
        }

        XCTAssertEqual(derive(rotate90: false, invertY: false).axis, .y)
        XCTAssertEqual(derive(rotate90: false, invertY: false).inverted, true)

        XCTAssertEqual(derive(rotate90: false, invertY: true).axis, .y)
        XCTAssertEqual(derive(rotate90: false, invertY: true).inverted, false)

        XCTAssertEqual(derive(rotate90: true, invertY: false).axis, .x)
        XCTAssertEqual(derive(rotate90: true, invertY: false).inverted, true)

        // The Go60 case (also pinned by testGo60DirectionTruthTable).
        XCTAssertEqual(derive(rotate90: true, invertY: true).axis, .x)
        XCTAssertEqual(derive(rotate90: true, invertY: true).inverted, false)

        // The system preference and the reverse toggle each XOR onto the
        // orientation baseline, for every orientation.
        for rotate90 in [false, true] {
            for invertY in [false, true] {
                let capabilities = TouchStreamCapabilities(rotate90: rotate90, invertY: invertY)
                let baseline = capabilities.orientationScrollInverted
                for systemPrefersNatural in [false, true] {
                    for reversed in [false, true] {
                        XCTAssertEqual(
                            capabilities.scrollInverted(
                                systemPrefersNatural: systemPrefersNatural,
                                reversed: reversed
                            ),
                            (baseline != systemPrefersNatural) != reversed,
                            "rotate90=\(rotate90) invertY=\(invertY) "
                                + "natural=\(systemPrefersNatural) reversed=\(reversed)"
                        )
                    }
                }
            }
        }
    }
}
