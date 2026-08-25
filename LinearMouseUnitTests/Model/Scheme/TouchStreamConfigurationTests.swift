// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class TouchStreamConfigurationTests: XCTestCase {
    func testDecodesSchemeScopedTouchStream() throws {
        let configuration = try Configuration.load(from: """
        {
            "schemes": [
                {
                    "if": { "device": { "vendorID": "0x16c0", "productID": "0x27d9" } },
                    "scrolling": {
                        "touchStream": {
                            "enabled": true,
                            "scale": 0.6,
                            "acceleration": {
                                "enabled": true,
                                "exponent": 0.5,
                                "referenceSpeed": 800,
                                "minGain": 0.4,
                                "maxGain": 3.0
                            },
                            "momentum": {
                                "decayTimeConstant": 0.83,
                                "startThreshold": 100,
                                "maxSpeed": 8000
                            }
                        }
                    }
                }
            ]
        }
        """)

        let touchStream = try XCTUnwrap(configuration.schemes.first?.scrolling.$touchStream)
        XCTAssertTrue(touchStream.isEnabled)
        XCTAssertEqual(touchStream.resolvedScale, 0.6)
        XCTAssertEqual(touchStream.acceleration?.isEnabled, true)
        XCTAssertEqual(touchStream.acceleration?.resolvedExponent, 0.5)
        XCTAssertEqual(touchStream.acceleration?.resolvedReferenceSpeed, 800)
        XCTAssertEqual(touchStream.acceleration?.resolvedMinGain, 0.4)
        XCTAssertEqual(touchStream.acceleration?.resolvedMaxGain, 3.0)
        XCTAssertEqual(try XCTUnwrap(touchStream.momentum?.resolvedDecayTimeConstant), 0.83, accuracy: 1e-9)
        XCTAssertEqual(touchStream.momentum?.resolvedStartThreshold, 100)
        XCTAssertEqual(touchStream.momentum?.resolvedMaxSpeed, 8000)
        XCTAssertFalse(touchStream.isTapToClickEnabled)
    }

    /// The old top-level `touchStream` key is gone; Codable must simply
    /// ignore it rather than crash or fail to parse.
    func testIgnoresLegacyTopLevelTouchStreamKey() throws {
        let configuration = try Configuration.load(from: """
        {
            "schemes": [],
            "touchStream": {
                "enabled": true,
                "scale": 0.6,
                "invert": false,
                "axis": "x"
            }
        }
        """)

        XCTAssertEqual(configuration.schemes.count, 0)
    }

    /// The removed `axis`/`invert` keys (superseded by feature-report
    /// auto-configuration) and the removed `direction` key (superseded by
    /// the scheme's generic `scrolling.reverse` toggle) are unknown keys
    /// inside the scheme-scoped object and must be ignored as well.
    func testIgnoresRemovedAxisInvertAndDirectionKeys() throws {
        let configuration = try Configuration.load(from: """
        {
            "schemes": [
                {
                    "scrolling": {
                        "touchStream": { "scale": 0.5, "axis": "x", "invert": true, "direction": "inverted" }
                    }
                }
            ]
        }
        """)

        let touchStream = try XCTUnwrap(configuration.schemes.first?.scrolling.$touchStream)
        XCTAssertEqual(touchStream.resolvedScale, 0.5)

        // The legacy key must not survive a round-trip either.
        let dumped = try XCTUnwrap(String(data: configuration.dump(), encoding: .utf8))
        XCTAssertFalse(dumped.contains("direction"))
    }

    func testDefaults() {
        let touchStream = Scheme.Scrolling.TouchStream()
        XCTAssertTrue(touchStream.isEnabled)
        XCTAssertEqual(touchStream.resolvedScale, 0.25)
        XCTAssertFalse(touchStream.isTapToClickEnabled)

        let momentum = Scheme.Scrolling.TouchStream.Momentum()
        XCTAssertEqual(momentum.resolvedDecayTimeConstant, 0.83)
        XCTAssertEqual(momentum.resolvedStartThreshold, 100)
        XCTAssertEqual(momentum.resolvedMaxSpeed, 8000)
    }

    func testParticipatesInSchemeMatchingAndMerging() throws {
        let configuration = try Configuration.load(from: """
        {
            "schemes": [
                {
                    "scrolling": {
                        "touchStream": { "scale": 0.3 }
                    }
                },
                {
                    "if": { "device": { "vendorID": "0x16c0", "productID": "0x27d9" } },
                    "scrolling": {
                        "touchStream": { "scale": 0.6, "momentum": { "startThreshold": 50 } }
                    }
                }
            ]
        }
        """)

        let matched = configuration.matchScheme(
            withDeviceMatcher: DeviceMatcher(
                vendorID: 0x16C0,
                productID: 0x27D9,
                productName: nil,
                serialNumber: nil,
                category: nil
            )
        )
        let touchStream = try XCTUnwrap(matched.scrolling.$touchStream)
        XCTAssertEqual(touchStream.resolvedScale, 0.6)
        XCTAssertEqual(touchStream.momentum?.resolvedStartThreshold, 50)

        let unmatched = configuration.matchScheme(
            withDeviceMatcher: DeviceMatcher(
                vendorID: 0x1234,
                productID: 0x5678,
                productName: nil,
                serialNumber: nil,
                category: nil
            )
        )
        XCTAssertEqual(unmatched.scrolling.$touchStream?.resolvedScale, 0.3)
    }

    func testMergePreservesUnsetLeaves() {
        var base = Scheme.Scrolling.TouchStream(
            scale: 0.6,
            acceleration: .init(enabled: true, exponent: 0.5)
        )
        let overlay = Scheme.Scrolling.TouchStream(
            acceleration: .init(minGain: 0.2)
        )

        overlay.merge(into: &base)

        XCTAssertEqual(base.scale, 0.6)
        XCTAssertEqual(base.acceleration?.enabled, true)
        XCTAssertEqual(base.acceleration?.exponent, 0.5)
        XCTAssertEqual(base.acceleration?.minGain, 0.2)
    }

    func testRoundTripsThroughDump() throws {
        let configuration = try Configuration.load(from: """
        {
            "schemes": [
                {
                    "scrolling": {
                        "touchStream": { "scale": 0.6, "momentum": { "decayTimeConstant": 1.2 } }
                    }
                }
            ]
        }
        """)

        let dumped = try configuration.dump()
        let reloaded = try Configuration.load(from: dumped)
        XCTAssertEqual(
            reloaded.schemes.first?.scrolling.$touchStream,
            configuration.schemes.first?.scrolling.$touchStream
        )
    }
}
