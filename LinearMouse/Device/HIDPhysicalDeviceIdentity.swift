// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Foundation
import IOKit
import IOKit.hid

/// Identity of the physical device behind an `IOHIDDevice`, used to decide
/// whether two HID handles belong to the same piece of hardware.
///
/// Vendor/product IDs cannot do this: two different keyboards can (and, for
/// ZMK firmware, do by default) share the same VID/PID, so anything keyed on
/// the VID/PID pair conflates them. At the same time, macOS splits a device's
/// HID top-level collections into separate `IOHIDDevice` handles — a
/// keyboard's vendor (touch stream) collection and its mouse collection are
/// different handles — so plain handle/registry-ID equality is not enough
/// either. This type captures several per-hardware discriminators and
/// compares them with a fixed precedence:
///
/// 1. `registryID` — equality means the two handles are literally the same
///    kernel service (collections not split on this transport/OS). Inequality
///    proves nothing (sibling collections differ), so the comparison falls
///    through.
/// 2. `locationID` — on USB, all interfaces/collections of one physical
///    device inherit the device's location ID, and two simultaneously
///    connected devices always have different ones. Decisive either way when
///    both sides have a non-zero value. Checked before the serial number
///    because ZMK keyboards may ship a firmware-constant serial string that
///    is identical across units.
/// 3. `serialNumber` — decisive when both sides have a non-empty value and
///    at least one side lacks a location ID (typically Bluetooth/BLE, where
///    macOS reports the unique radio address as the HID serial). Failure
///    mode: two units connected in a way that yields no location IDs *and*
///    identical firmware-constant serials would falsely match; this cannot
///    happen over USB (location IDs always present) or Bluetooth (addresses
///    are unique).
/// 4. `transportAncestorRegistryID` — the IORegistry node just above the HID
///    layer (USB interface / Bluetooth device node), shared by sibling
///    collections enumerated from the same interface. Last resort when the
///    property-based discriminators are unavailable. Inequality here is
///    treated as "different", which can misreport a single device that
///    exposes its collections on different USB interfaces — acceptable,
///    because the conservative direction is "not the same device".
///
/// If no discriminator is available on both sides the answer is `false`:
/// callers must treat "indeterminate" as "not the same device". For wheel
/// suppression that means fallback wheel events pass through (a visible
/// double-scroll) instead of silently killing another keyboard's scrolling.
struct HIDPhysicalDeviceIdentity: Hashable {
    /// Registry entry ID of the `IOHIDDevice` service itself.
    var registryID: UInt64?

    /// `kIOHIDLocationIDKey`; `nil` when absent or zero.
    var locationID: Int?

    /// `kIOHIDSerialNumberKey`; `nil` when absent or empty.
    var serialNumber: String?

    /// Registry entry ID of the nearest ancestor that is not part of the HID
    /// layer (see `transportAncestorRegistryID(startingAt:)`).
    var transportAncestorRegistryID: UInt64?

    init(
        registryID: UInt64? = nil,
        locationID: Int? = nil,
        serialNumber: String? = nil,
        transportAncestorRegistryID: UInt64? = nil
    ) {
        self.registryID = registryID
        self.locationID = locationID
        self.serialNumber = serialNumber
        self.transportAncestorRegistryID = transportAncestorRegistryID
    }

    /// Whether `other` refers to the same physical device, per the precedence
    /// documented on the type. Conservative: returns `false` when identity is
    /// indeterminate.
    func isSamePhysicalDevice(as other: HIDPhysicalDeviceIdentity) -> Bool {
        // Same kernel service: trivially the same hardware. (Different
        // services are expected for sibling collections — fall through.)
        if let mine = registryID, let theirs = other.registryID, mine == theirs {
            return true
        }

        if let mine = locationID, let theirs = other.locationID {
            return mine == theirs
        }

        if let mine = serialNumber, let theirs = other.serialNumber {
            return mine == theirs
        }

        if let mine = transportAncestorRegistryID, let theirs = other.transportAncestorRegistryID {
            return mine == theirs
        }

        return false
    }
}

extension HIDPhysicalDeviceIdentity {
    /// Captures the identity of the hardware behind `hidDevice`. Cheap
    /// property reads plus a bounded registry walk; call once per device at
    /// enumeration time, not per event.
    init(hidDevice: IOHIDDevice) {
        self.init()

        let service = IOHIDDeviceGetService(hidDevice)
        if service != 0 {
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                registryID = entryID
            }

            transportAncestorRegistryID = Self.transportAncestorRegistryID(startingAt: service)
        }

        if let location = IOHIDDeviceGetProperty(hidDevice, kIOHIDLocationIDKey as CFString) as? Int,
           location != 0 {
            locationID = location
        }

        if let serial = IOHIDDeviceGetProperty(hidDevice, kIOHIDSerialNumberKey as CFString) as? String,
           !serial.isEmpty {
            serialNumber = serial
        }
    }

    /// Walks up the IOService plane from a HID service, skipping HID-layer
    /// nodes (`IOHIDDevice` subclasses — one per split collection — and any
    /// `IOHIDInterface` shims), and returns the registry entry ID of the
    /// first transport-level node: the USB interface or Bluetooth device
    /// entry shared by sibling collections of the same physical device.
    ///
    /// The walk is bounded so an unexpected registry shape can only produce
    /// `nil` (indeterminate), never an unrelated ancestor near the root that
    /// different devices might share.
    private static func transportAncestorRegistryID(startingAt service: io_service_t) -> UInt64? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0 ..< 8 {
            let isHIDLayer = IOObjectConformsTo(current, "IOHIDDevice") != 0
                || IOObjectConformsTo(current, "IOHIDInterface") != 0

            guard isHIDLayer else {
                var entryID: UInt64 = 0
                guard IORegistryEntryGetRegistryEntryID(current, &entryID) == KERN_SUCCESS else {
                    return nil
                }
                return entryID
            }

            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0
            else {
                return nil
            }

            IOObjectRelease(current)
            current = parent
        }

        return nil
    }
}
