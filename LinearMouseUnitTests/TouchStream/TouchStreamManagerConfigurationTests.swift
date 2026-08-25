// MIT License
// Copyright (c) 2021-2026 LinearMouse

import Combine
@testable import LinearMouse
import XCTest

final class TouchStreamManagerConfigurationTests: XCTestCase {
    /// `@Published` emits during `willSet`, and
    /// `TouchStreamManager.reconfigure()` reads the *stored* configuration
    /// rather than the emitted value. Its subscription must therefore deliver
    /// only after the new value is committed — a synchronous delivery makes
    /// the engine consistently apply the PREVIOUS configuration (the
    /// reverse-scrolling toggle inverting the direction one toggle late).
    ///
    /// This drives the exact pipeline `start()` subscribes through and reads
    /// the configuration back the same way `reconfigure()` does (through the
    /// state object), asserting the read sees the just-committed value on
    /// every change.
    func testConfigurationChangesDeliverAfterTheNewValueIsCommitted() throws {
        let state = ConfigurationState()

        var observedReverse: [Bool] = []
        var subscriptions = Set<AnyCancellable>()

        TouchStreamManager.configurationChanges(state.$configuration)
            .dropFirst() // the replayed initial value
            .sink { _ in
                // Read through the state object, exactly as reconfigure()
                // resolves the scheme from ConfigurationState's stored value.
                observedReverse.append(
                    state.configuration.schemes.first?.scrolling.$reverse?.vertical ?? false
                )
            }
            .store(in: &subscriptions)

        for expected in [true, false, true] {
            let countBefore = observedReverse.count
            state.configuration = try Self.configuration(reverseVertical: expected)

            // Delivery is deferred to the next main-queue turn; spin the main
            // run loop until it lands.
            let deadline = Date().addingTimeInterval(2)
            while observedReverse.count == countBefore, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }

            XCTAssertEqual(
                observedReverse.last,
                expected,
                "engine configuration read must see the just-committed value, not the previous one"
            )
        }

        XCTAssertEqual(observedReverse, [true, false, true])
    }

    private static func configuration(reverseVertical: Bool) throws -> Configuration {
        try Configuration.load(from: """
        {
            "schemes": [
                {
                    "if": { "device": { "vendorID": "0x16c0", "productID": "0x27d9" } },
                    "scrolling": {
                        "reverse": { "vertical": \(reverseVertical) },
                        "touchStream": { "enabled": true }
                    }
                }
            ]
        }
        """)
    }
}
