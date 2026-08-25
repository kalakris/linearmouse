// MIT License
// Copyright (c) 2021-2026 LinearMouse

@testable import LinearMouse
import XCTest

final class HIDPhysicalDeviceIdentityTests: XCTestCase {
    // MARK: - Registry ID (same kernel service)

    func testSameRegistryIDMatches() {
        let a = HIDPhysicalDeviceIdentity(registryID: 100)
        let b = HIDPhysicalDeviceIdentity(registryID: 100)
        XCTAssertTrue(a.isSamePhysicalDevice(as: b))
    }

    func testDifferentRegistryIDsAloneAreIndeterminate() {
        // Sibling collections of the same keyboard are separate services, so
        // registry-ID inequality proves nothing; with no other discriminator
        // the conservative answer is "not the same device".
        let a = HIDPhysicalDeviceIdentity(registryID: 100)
        let b = HIDPhysicalDeviceIdentity(registryID: 200)
        XCTAssertFalse(a.isSamePhysicalDevice(as: b))
    }

    // MARK: - Location ID (USB)

    func testSplitCollectionsSharingLocationIDMatch() {
        // Vendor collection and mouse collection of the same USB keyboard:
        // different services, same USB location.
        let stream = HIDPhysicalDeviceIdentity(registryID: 100, locationID: 0x14200000)
        let pointer = HIDPhysicalDeviceIdentity(registryID: 101, locationID: 0x14200000)
        XCTAssertTrue(stream.isSamePhysicalDevice(as: pointer))
        XCTAssertTrue(pointer.isSamePhysicalDevice(as: stream))
    }

    func testDifferentLocationIDsDoNotMatch() {
        let go60 = HIDPhysicalDeviceIdentity(registryID: 100, locationID: 0x14200000)
        let sofle = HIDPhysicalDeviceIdentity(registryID: 200, locationID: 0x14300000)
        XCTAssertFalse(go60.isSamePhysicalDevice(as: sofle))
    }

    func testLocationIDDecidesBeforeSerialNumber() {
        // Two ZMK keyboards on USB with an identical firmware-constant
        // serial: the differing USB locations must win, or the Sofle's wheel
        // scrolling would be suppressed by the Go60's stream.
        let go60 = HIDPhysicalDeviceIdentity(
            registryID: 100,
            locationID: 0x14200000,
            serialNumber: "ZMK"
        )
        let sofle = HIDPhysicalDeviceIdentity(
            registryID: 200,
            locationID: 0x14300000,
            serialNumber: "ZMK"
        )
        XCTAssertFalse(go60.isSamePhysicalDevice(as: sofle))
    }

    // MARK: - Serial number (Bluetooth)

    func testSameSerialMatchesWhenLocationIDUnavailable() {
        // BLE: macOS reports the unique radio address as the HID serial.
        let stream = HIDPhysicalDeviceIdentity(registryID: 100, serialNumber: "aa-bb-cc-dd-ee-ff")
        let pointer = HIDPhysicalDeviceIdentity(registryID: 101, serialNumber: "aa-bb-cc-dd-ee-ff")
        XCTAssertTrue(stream.isSamePhysicalDevice(as: pointer))
    }

    func testDifferentSerialsDoNotMatch() {
        let a = HIDPhysicalDeviceIdentity(registryID: 100, serialNumber: "aa-bb-cc-dd-ee-ff")
        let b = HIDPhysicalDeviceIdentity(registryID: 200, serialNumber: "11-22-33-44-55-66")
        XCTAssertFalse(a.isSamePhysicalDevice(as: b))
    }

    func testUSBStreamNeverMatchesBluetoothPointerOfAnotherKeyboard() {
        // Go60 over USB (location + constant serial) vs. Sofle over BLE
        // (address serial, no location): serial comparison decides — the
        // strings differ, so no match.
        let go60USB = HIDPhysicalDeviceIdentity(
            registryID: 100,
            locationID: 0x14200000,
            serialNumber: "ZMK"
        )
        let sofleBLE = HIDPhysicalDeviceIdentity(
            registryID: 200,
            serialNumber: "11-22-33-44-55-66"
        )
        XCTAssertFalse(go60USB.isSamePhysicalDevice(as: sofleBLE))
    }

    // MARK: - Transport ancestor (fallback)

    func testSameTransportAncestorMatchesAsLastResort() {
        let a = HIDPhysicalDeviceIdentity(registryID: 100, transportAncestorRegistryID: 50)
        let b = HIDPhysicalDeviceIdentity(registryID: 101, transportAncestorRegistryID: 50)
        XCTAssertTrue(a.isSamePhysicalDevice(as: b))
    }

    func testDifferentTransportAncestorsDoNotMatch() {
        let a = HIDPhysicalDeviceIdentity(registryID: 100, transportAncestorRegistryID: 50)
        let b = HIDPhysicalDeviceIdentity(registryID: 200, transportAncestorRegistryID: 60)
        XCTAssertFalse(a.isSamePhysicalDevice(as: b))
    }

    func testHigherPrecedenceDiscriminatorShadowsAncestor() {
        // Location inequality is decisive even when a (bogus) shared ancestor
        // is present.
        let a = HIDPhysicalDeviceIdentity(
            locationID: 0x14200000,
            transportAncestorRegistryID: 50
        )
        let b = HIDPhysicalDeviceIdentity(
            locationID: 0x14300000,
            transportAncestorRegistryID: 50
        )
        XCTAssertFalse(a.isSamePhysicalDevice(as: b))
    }

    // MARK: - Indeterminate

    func testEmptyIdentitiesNeverMatch() {
        let a = HIDPhysicalDeviceIdentity()
        let b = HIDPhysicalDeviceIdentity()
        XCTAssertFalse(a.isSamePhysicalDevice(as: b))
    }

    func testDisjointDiscriminatorsAreIndeterminate() {
        // One side only has a location, the other only a serial: nothing is
        // comparable, so the conservative answer is "not the same device".
        let a = HIDPhysicalDeviceIdentity(locationID: 0x14200000)
        let b = HIDPhysicalDeviceIdentity(serialNumber: "aa-bb-cc-dd-ee-ff")
        XCTAssertFalse(a.isSamePhysicalDevice(as: b))
        XCTAssertFalse(b.isSamePhysicalDevice(as: a))
    }

    // MARK: - Protocol constants

    func testTouchStreamInputReportIDMatchesFeatureReportID() {
        // The input filter in TouchStreamManager and the feature-report read
        // must stay on the same frozen protocol report ID (0x04).
        XCTAssertEqual(TouchStreamFrame.reportID, 0x04)
        XCTAssertEqual(CFIndex(TouchStreamFrame.reportID), TouchStreamCapabilities.featureReportID)
    }
}
