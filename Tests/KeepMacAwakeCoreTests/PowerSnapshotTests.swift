import Foundation
import XCTest
@testable import KeepMacAwakeCore

final class PowerSnapshotTests: XCTestCase {
    func testFullBatteryOnACWithoutChargingRemainsAC() {
        let result = map(internalBattery(source: "AC Power", current: 100, charging: false))

        XCTAssertEqual(result.snapshot.source, .ac)
        XCTAssertEqual(result.snapshot.batteryPercent, 100)
        XCTAssertEqual(result.snapshot.isCharging, false)
    }

    func testMissingSourceIsUnknownEvenWhileCharging() {
        let result = map(internalBattery(source: nil, charging: true))

        XCTAssertEqual(result.snapshot.source, .unknown)
    }

    func testUnrecognizedSourceIsUnknown() {
        let result = map(internalBattery(source: "Unexpected Source"))

        XCTAssertEqual(result.snapshot.source, .unknown)
    }

    func testBatterySourceIsBattery() {
        let result = map(internalBattery(source: "Battery Power", current: 37, charging: false))

        XCTAssertEqual(result.snapshot.source, .battery)
        XCTAssertEqual(result.snapshot.batteryPercent, 37)
    }

    func testMissingLidSensorIsUnknown() {
        let result = map(internalBattery(), lidState: nil)

        XCTAssertNil(result.snapshot.lidClosed)
    }

    func testLidSensorPreservesClosedAndOpenStates() {
        XCTAssertEqual(map(internalBattery(), lidState: true).snapshot.lidClosed, true)
        XCTAssertEqual(map(internalBattery(), lidState: false).snapshot.lidClosed, false)
    }

    func testUPSAndAccessoryDescriptionsCannotReplaceInternalBattery() {
        for externalType in ["UPS", "Accessory"] {
            let external = replacing(internalBattery(source: "AC Power"), "Type", with: externalType)
            let battery = internalBattery(source: "Battery Power", current: 37)
            let result = PowerSnapshotMapper.map(descriptions: [external, battery], lidState: false)

            XCTAssertEqual(result.snapshot.source, .battery)
            XCTAssertEqual(result.snapshot.batteryPercent, 37)
        }
    }

    func testExternalSourcesAloneCannotConfirmMacBookAC() {
        let external = replacing(internalBattery(), "Type", with: "UPS")
        let result = map(external)

        XCTAssertEqual(result.snapshot.source, .unknown)
        XCTAssertNil(result.snapshot.batteryPercent)
        XCTAssertNil(result.snapshot.isCharging)
        XCTAssertEqual(result.issues, [.internalBatteryUnavailable])
    }

    func testAbsentInternalBatteryDoesNotProvideMeasurements() {
        let result = map(replacing(internalBattery(), "Is Present", with: false))

        XCTAssertEqual(result.snapshot.source, .unknown)
        XCTAssertNil(result.snapshot.batteryPercent)
        XCTAssertEqual(result.issues, [.internalBatteryUnavailable])
    }

    func testMissingOrMalformedBatteryPresenceIsNotAssumedPresent() {
        for value: Any? in [nil, 1, "true"] {
            let result = map(replacing(internalBattery(), "Is Present", with: value))

            XCTAssertEqual(result.snapshot.source, .unknown)
            XCTAssertTrue(result.issues.contains(.batteryPresenceInvalid))
        }
    }

    func testMultiplePresentInternalBatteriesAreExplicitlyAmbiguous() {
        let result = PowerSnapshotMapper.map(
            descriptions: [internalBattery(source: "AC Power"), internalBattery(source: "Battery Power")],
            lidState: false
        )

        XCTAssertEqual(result.snapshot.source, .unknown)
        XCTAssertNil(result.snapshot.batteryPercent)
        XCTAssertNil(result.snapshot.isCharging)
        XCTAssertEqual(result.issues, [.internalBatteryAmbiguous])
    }

    func testMissingOrMalformedSourceTypeIsNotAnInternalBattery() {
        for value: Any? in [nil, 1, true] {
            let result = map(replacing(internalBattery(), "Type", with: value))

            XCTAssertEqual(result.snapshot.source, .unknown)
            XCTAssertTrue(result.issues.contains(.powerSourceTypeInvalid))
        }
    }

    func testCapacityIsNormalizedUsingTheReportedMaximum() {
        let description = replacing(internalBattery(current: 1), "Max Capacity", with: 3)

        XCTAssertEqual(map(description).snapshot.batteryPercent, 33)
    }

    func testInvalidCapacitiesRemainUnknownInsteadOfClampingOrOverflowing() {
        let invalidPairs: [(Any, Any)] = [
            (-1, 100), (101, 100), (1, 0), (0, -1),
            (true, 100), ("50", 100), (50.5, 100), (50, true),
            (Double.nan, 100), (Double.infinity, 100), (UInt64.max, 100),
        ]
        for (current, maximum) in invalidPairs {
            let description = replacing(
                replacing(internalBattery(), "Current Capacity", with: current),
                "Max Capacity", with: maximum
            )
            let result = map(description)

            XCTAssertNil(result.snapshot.batteryPercent)
            XCTAssertTrue(result.issues.contains(.batteryCapacityInvalid))
            XCTAssertEqual(result.snapshot.source, .ac)
        }
    }

    func testLargeIntegerCapacitiesDoNotOverflow() {
        let description = replacing(
            replacing(internalBattery(), "Current Capacity", with: Int64.max),
            "Max Capacity", with: Int64.max
        )

        XCTAssertEqual(map(description).snapshot.batteryPercent, 100)
    }

    func testMissingCapacityIsExplicitlyUnavailable() {
        for key in ["Current Capacity", "Max Capacity"] {
            let result = map(replacing(internalBattery(), key, with: nil))

            XCTAssertNil(result.snapshot.batteryPercent)
            XCTAssertTrue(result.issues.contains(.batteryCapacityUnavailable))
        }
    }

    func testNumbersAndStringsAreNotBooleanSensors() {
        for value: Any in [0, 1, "true", "false"] {
            let result = map(replacing(internalBattery(), "Is Charging", with: value), lidState: value)

            XCTAssertNil(result.snapshot.isCharging)
            XCTAssertNil(result.snapshot.lidClosed)
            XCTAssertTrue(result.issues.contains(.chargingStateInvalid))
            XCTAssertTrue(result.issues.contains(.lidStateInvalid))
        }
    }

    func testMissingFieldsHaveSanitizedIssueCodes() {
        let description = replacing(internalBattery(source: nil), "Is Charging", with: nil)
        let result = map(description, lidState: nil)

        XCTAssertTrue(result.issues.contains(.powerSourceStateUnavailable))
        XCTAssertTrue(result.issues.contains(.chargingStateUnavailable))
        XCTAssertTrue(result.issues.contains(.lidStateUnavailable))
    }

    func testUnexpectedSourceValueIsNotIncludedInEncodedDiagnostics() throws {
        let result = map(internalBattery(source: "private arbitrary raw value"))
        let data = try JSONEncoder().encode(result)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(result.issues.contains(.powerSourceStateInvalid))
        XCTAssertFalse(json.contains("private arbitrary raw value"))
        XCTAssertEqual(try JSONDecoder().decode(PowerProbeResult.self, from: data), result)
    }

    func testAbsentBatteryBeforePresentBatteryIsIgnored() {
        let absent = replacing(internalBattery(source: "AC Power"), "Is Present", with: false)
        let present = internalBattery(source: "Battery Power", current: 37)
        let result = PowerSnapshotMapper.map(descriptions: [absent, present], lidState: false)

        XCTAssertEqual(result.snapshot.source, .battery)
        XCTAssertEqual(result.snapshot.batteryPercent, 37)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testProbeMapsInjectedNativeReadings() {
        let description = internalBattery(source: "AC Power", current: 100, charging: false)
        let probe = SystemProbe(
            readPowerSources: { .value([description]) },
            readLidState: { .value(true) }
        )

        XCTAssertEqual(probe.read(), PowerProbeResult(snapshot: PowerSnapshot(
            source: .ac, batteryPercent: 100, isCharging: false, lidClosed: true
        )))
    }

    func testUnavailablePowerReadDoesNotDiscardLidData() {
        for issue: PowerProbeIssue in [
            .powerSourcesUnavailable, .powerSourceListUnavailable, .powerSourceDescriptionUnavailable,
        ] {
            let probe = SystemProbe(
                readPowerSources: { .unavailable(issue) },
                readLidState: { .value(false) }
            )
            let result = probe.read()

            XCTAssertEqual(result.snapshot.source, .unknown)
            XCTAssertNil(result.snapshot.batteryPercent)
            XCTAssertNil(result.snapshot.isCharging)
            XCTAssertEqual(result.snapshot.lidClosed, false)
            XCTAssertEqual(result.issues, [issue])
        }
    }

    func testUnavailableLidReadDoesNotDiscardPowerData() {
        let description = internalBattery(source: "Battery Power", current: 37)
        for issue: PowerProbeIssue in [.lidServiceUnavailable, .lidStateUnavailable] {
            let probe = SystemProbe(
                readPowerSources: { .value([description]) },
                readLidState: { .unavailable(issue) }
            )
            let result = probe.read()

            XCTAssertEqual(result.snapshot.source, .battery)
            XCTAssertEqual(result.snapshot.batteryPercent, 37)
            XCTAssertNil(result.snapshot.lidClosed)
            XCTAssertEqual(result.issues, [issue])
        }
    }

    func testDesktopOnACIsAC() {
        let result = PowerSnapshotMapper.map(descriptions: [], lidState: nil, providingSource: "AC Power",
                                             hasBatteryService: false)

        XCTAssertEqual(result, PowerProbeResult(snapshot: PowerSnapshot(
            source: .ac, batteryPercent: nil, isCharging: nil, lidClosed: nil
        ), isDesktop: true))
    }

    func testDesktopWithAUPSOnMainsIsAC() {
        let ups = replacing(internalBattery(source: "AC Power"), "Type", with: "UPS")
        let result = PowerSnapshotMapper.map(descriptions: [ups], lidState: nil, providingSource: "AC Power",
                                             hasBatteryService: false)

        XCTAssertEqual(result.snapshot.source, .ac)
        XCTAssertNil(result.snapshot.batteryPercent)
        XCTAssertTrue(result.isDesktop)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testDesktopOnAUPSBatteryHasNoACAndNoLevel() {
        for providing in ["UPS Power", "Battery Power"] {
            let ups = replacing(internalBattery(source: "Battery Power", current: 80), "Type", with: "UPS")
            let result = PowerSnapshotMapper.map(descriptions: [ups], lidState: nil, providingSource: providing,
                                                 hasBatteryService: false)

            XCTAssertEqual(result.snapshot.source, .battery, providing)
            XCTAssertNil(result.snapshot.batteryPercent, providing)
            XCTAssertTrue(result.isDesktop, providing)
        }
    }

    func testDesktopWithoutAProvidingSourceIsUnknown() {
        let missing = PowerSnapshotMapper.map(descriptions: [], lidState: nil, providingSource: nil,
                                             hasBatteryService: false)
        XCTAssertEqual(missing.snapshot.source, .unknown)
        XCTAssertEqual(missing.issues, [.powerSourceStateUnavailable])
        XCTAssertTrue(missing.isDesktop)

        let odd = PowerSnapshotMapper.map(descriptions: [], lidState: nil, providingSource: "private raw value",
                                             hasBatteryService: false)
        XCTAssertEqual(odd.snapshot.source, .unknown)
        XCTAssertEqual(odd.issues, [.powerSourceStateInvalid])
    }

    func testAMacBookWithAFailedBatteryReadNeverCountsAsADesktop() {
        // A lid state, even with no battery entry at all.
        let withLid = PowerSnapshotMapper.map(descriptions: [], lidState: false, providingSource: "AC Power",
                                             hasBatteryService: false)
        XCTAssertEqual(withLid.snapshot.source, .unknown)
        XCTAssertEqual(withLid.issues, [.internalBatteryUnavailable])
        XCTAssertFalse(withLid.isDesktop)

        // A built-in battery entry, even an absent one, with no lid state.
        let absent = replacing(internalBattery(), "Is Present", with: false)
        let withBatteryEntry = PowerSnapshotMapper.map(descriptions: [absent], lidState: nil, providingSource: "AC Power",
                                             hasBatteryService: false)
        XCTAssertEqual(withBatteryEntry.snapshot.source, .unknown)
        XCTAssertFalse(withBatteryEntry.isDesktop)

        // An entry whose type cannot be read.
        let untyped = replacing(internalBattery(), "Type", with: nil)
        let withUntyped = PowerSnapshotMapper.map(descriptions: [untyped], lidState: nil, providingSource: "AC Power",
                                             hasBatteryService: false)
        XCTAssertEqual(withUntyped.snapshot.source, .unknown)
        XCTAssertFalse(withUntyped.isDesktop)
    }

    func testFailedReadsNeverCountAsADesktop() {
        let lidServiceMissing = SystemProbe(
            readPowerSources: { .value([]) },
            readLidState: { .unavailable(.lidServiceUnavailable) },
            readProvidingSource: { .value("AC Power") },
            readHasBatteryService: { false }
        ).read()
        XCTAssertEqual(lidServiceMissing.snapshot.source, .unknown)
        XCTAssertFalse(lidServiceMissing.isDesktop)

        for issue: PowerProbeIssue in [
            .powerSourcesUnavailable, .powerSourceListUnavailable, .powerSourceDescriptionUnavailable,
        ] {
            let powerMissing = SystemProbe(
                readPowerSources: { .unavailable(issue) },
                readLidState: { .unavailable(.lidStateUnavailable) },
                readProvidingSource: { .value("AC Power") },
                readHasBatteryService: { false }
            ).read()
            XCTAssertEqual(powerMissing.snapshot.source, .unknown)
            XCTAssertFalse(powerMissing.isDesktop)
        }
    }

    func testABatteryServiceKeepsAMacBookOffTheDesktopPath() {
        // Early in boot the list and the lid state may both be missing; the kernel's battery service is not.
        let result = PowerSnapshotMapper.map(descriptions: [], lidState: nil, providingSource: "AC Power",
                                             hasBatteryService: true)

        XCTAssertEqual(result.snapshot.source, .unknown)
        XCTAssertEqual(result.issues, [.internalBatteryUnavailable, .lidStateUnavailable])
        XCTAssertFalse(result.isDesktop)
    }

    func testAMacBookWithoutALidStateNeverReadsTheDesktopSignals() {
        var reads = 0
        let probe = SystemProbe(
            readPowerSources: { .value([self.internalBattery(source: "Battery Power", current: 40)]) },
            readLidState: { .unavailable(.lidStateUnavailable) },
            readProvidingSource: { reads += 1; return .value("AC Power") },
            readHasBatteryService: { reads += 1; return false }
        )

        XCTAssertEqual(probe.read().snapshot.source, .battery)
        XCTAssertEqual(reads, 0)
    }

    func testReadingsFromBeforeBuild22DecodeAsNotDesktop() throws {
        let data = Data(#"{"snapshot":{"source":"ac","batteryPercent":90,"isCharging":false,"lidClosed":true},"issues":[]}"#.utf8)
        let result = try JSONDecoder().decode(PowerProbeResult.self, from: data)

        XCTAssertFalse(result.isDesktop)
        XCTAssertEqual(result.snapshot.source, .ac)
    }

    func testAMacBookNeverReadsTheProvidingSource() {
        var reads = 0
        let probe = SystemProbe(
            readPowerSources: { .value([self.internalBattery(source: "Battery Power", current: 40)]) },
            readLidState: { .value(true) },
            readProvidingSource: { reads += 1; return .value("AC Power") }
        )

        XCTAssertEqual(probe.read().snapshot.source, .battery)
        XCTAssertEqual(reads, 0)
    }

    func testAMacBookKindIsSettledByItsBatteryServiceAlone() {
        var powerReads = 0
        let probe = SystemProbe(
            readPowerSources: { powerReads += 1; return .value([]) },
            readLidState: { .unavailable(.lidStateUnavailable) },
            readProvidingSource: { .value("AC Power") },
            readHasBatteryService: { true }
        )

        XCTAssertEqual(probe.readKind(), false)
        XCTAssertEqual(powerReads, 0)
    }

    func testADesktopKindNeedsAFullDesktopReading() {
        let desktop = SystemProbe(
            readPowerSources: { .value([]) },
            readLidState: { .unavailable(.lidStateUnavailable) },
            readProvidingSource: { .value("AC Power") },
            readHasBatteryService: { false }
        )
        XCTAssertEqual(desktop.readKind(), true)

        let unsettled = SystemProbe(
            readPowerSources: { .unavailable(.powerSourcesUnavailable) },
            readLidState: { .unavailable(.lidStateUnavailable) },
            readProvidingSource: { .value("AC Power") },
            readHasBatteryService: { false }
        )
        XCTAssertNil(unsettled.readKind())
    }

    func testUnknownSnapshotEncodesExplicitNullValues() throws {
        let snapshot = PowerSnapshot(source: .unknown, batteryPercent: nil, isCharging: nil, lidClosed: nil)
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertTrue(object["batteryPercent"] is NSNull)
        XCTAssertTrue(object["isCharging"] is NSNull)
        XCTAssertTrue(object["lidClosed"] is NSNull)
    }

    private func replacing(_ description: NSDictionary, _ key: String, with value: Any?) -> NSDictionary {
        let copy = description.mutableCopy() as! NSMutableDictionary
        if let value {
            copy[key] = value
        } else {
            copy.removeObject(forKey: key)
        }
        return copy
    }

    private func map(_ description: NSDictionary, lidState: Any? = false) -> PowerProbeResult {
        PowerSnapshotMapper.map(descriptions: [description], lidState: lidState)
    }

    private func internalBattery(
        source: String? = "AC Power",
        current: Int = 50,
        charging: Bool = true
    ) -> NSDictionary {
        var description: [String: Any] = [
            "Type": "InternalBattery",
            "Is Present": true,
            "Current Capacity": current,
            "Max Capacity": 100,
            "Is Charging": charging,
        ]
        description["Power Source State"] = source
        return description as NSDictionary
    }
}
