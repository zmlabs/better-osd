//
//  DDCBrightnessClientTests.swift
//  BetterOSD
//
//  Created by yu on 2026/8/31.
//

import AppKit
import CoreGraphics
import Foundation
@testable import BetterOSD
import Testing

@MainActor
struct DDCBrightnessClientTests {
    /// Fixed fake display so tests don't depend on the host's monitor layout.
    private static let candidate: DDCDisplayCandidateProvider = {
        (displayID: 42, displayKey: "0x10ac:0x437d:1112950348")
    }

    private let noDisplay: DDCDisplayCandidateProvider = { nil }

    @Test
    func returnsNilWhenNoExternalDisplay() {
        let client = DDCBrightnessClient(
            transportProvider: { _ in nil },
            displayCandidateProvider: noDisplay,
            defaults: makeDefaults()
        )

        #expect(client.currentBrightness() == nil)
        #expect(client.setBrightness(0.5) == false)
    }

    @Test
    func readsSaneLuminanceAndCachesIt() {
        let defaults = makeDefaults()
        let transport = FakeDDCTransport(lastReadLuminance: (current: 50, max: 100))
        var resolveCount = 0
        let client = DDCBrightnessClient(
            transportProvider: { _ in
                resolveCount += 1
                return transport
            },
            displayCandidateProvider: Self.candidate,
            defaults: defaults
        )

        // DDC 50/100 covers [0.25 … 1] of our domain: 0.25 + 0.5 × 0.75.
        #expect(client.currentBrightness() == 0.625)
        #expect(client.currentBrightness() == 0.625)
        #expect(resolveCount == 1)

        // Cache survives a fresh client instance (persisted per display).
        let revived = DDCBrightnessClient(
            transportProvider: { _ in FakeDDCTransport(lastReadLuminance: nil) },
            displayCandidateProvider: Self.candidate,
            defaults: defaults
        )
        #expect(revived.currentBrightness() == 0.625)
    }

    @Test
    func fallsBackToAssumedBrightnessWhenReadIsGarbage() {
        // Dell Display Manager-style garbage reply: sanity check rejects it.
        let transport = FakeDDCTransport(lastReadLuminance: nil)
        let defaults = makeDefaults()
        let client = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: Self.candidate,
            defaults: defaults
        )

        #expect(client.currentBrightness() == 0.75)
    }

    @Test
    func writesScaledValueAndCachesResult() {
        let transport = FakeDDCTransport(lastReadLuminance: (current: 50, max: 100))
        let defaults = makeDefaults()
        let client = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: Self.candidate,
            defaults: defaults
        )

        // 0.625 maps to the upper half of the hardware range: 0.5 × 100.
        #expect(client.setBrightness(0.625) == true)
        #expect(transport.writtenValues == [50])

        // No sane read available anymore → cached written value wins.
        #expect(client.currentBrightness() == 0.625)
        #expect(transport.writeCallCount == 1)
    }

    @Test
    func assumesHundredScaleWhenMaxUnknown() {
        let transport = FakeDDCTransport(lastReadLuminance: nil)
        let client = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: Self.candidate,
            defaults: makeDefaults()
        )

        #expect(client.setBrightness(0.5) == true)
        #expect(transport.writtenValues == [33])
    }

    @Test
    func writeFailureInvalidatesTransportForReResolve() {
        let failing = FakeDDCTransport(lastReadLuminance: nil)
        failing.writeResult = false
        let fresh = FakeDDCTransport(lastReadLuminance: nil)
        var provided: [FakeDDCTransport] = [failing, fresh]
        let client = DDCBrightnessClient(
            transportProvider: { _ in provided.removeFirst() },
            displayCandidateProvider: Self.candidate,
            defaults: makeDefaults()
        )

        #expect(client.setBrightness(0.5) == false)
        #expect(failing.writeCallCount == 1)
        #expect(fresh.writeCallCount == 0)

        #expect(client.setBrightness(0.5) == true)
        #expect(fresh.writtenValues == [33])
    }

    @Test
    func targetedWriteUsesExplicitDisplayIDIgnoringCandidate() {
        let transport = FakeDDCTransport(lastReadLuminance: (current: 50, max: 100))
        var resolvedIDs: [CGDirectDisplayID] = []
        let client = DDCBrightnessClient(
            transportProvider: { displayID in
                resolvedIDs.append(displayID)
                return transport
            },
            displayCandidateProvider: noDisplay,
            defaults: makeDefaults()
        )

        #expect(client.setBrightness(0.5, ofDisplay: 7) == true)
        #expect(transport.writtenValues == [33])
        #expect(resolvedIDs == [7])

        // Written value is cached per display.
        #expect(client.currentBrightness(ofDisplay: 7) == 0.5)
    }

    // MARK: - Software dimming below the DDC floor

    @Test
    func belowFloorPinsDDCAtZeroAndDimsViaGamma() {
        let transport = FakeDDCTransport(lastReadLuminance: nil)
        var gammaCalls: [(displayID: CGDirectDisplayID, factor: Float)] = []
        let client = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: Self.candidate,
            defaults: makeDefaults(),
            gammaDimming: { gammaCalls.append((displayID: $0, factor: $1)) }
        )

        #expect(client.setBrightness(0.125) == true)
        #expect(transport.writtenValues == [0])
        #expect(gammaCalls.map(\.displayID) == [42])
        #expect(gammaCalls.map(\.factor) == [0.5])

        #expect(client.currentBrightness() == 0.125)
    }

    @Test
    func risingBackAboveFloorRestoresGammaOnce() {
        let transport = FakeDDCTransport(lastReadLuminance: nil)
        var gammaFactors: [Float] = []
        let client = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: Self.candidate,
            defaults: makeDefaults(),
            gammaDimming: { _, factor in gammaFactors.append(factor) }
        )

        #expect(client.setBrightness(0) == true)
        #expect(transport.writtenValues == [0])
        #expect(gammaFactors == [0])

        // Crossing back above the floor restores identity gamma exactly once…
        #expect(client.setBrightness(0.5) == true)
        #expect(transport.writtenValues == [0, 33])
        #expect(gammaFactors == [0, 1])

        // …and further above-floor writes leave the gamma tables alone.
        #expect(client.setBrightness(0.75) == true)
        #expect(gammaFactors == [0, 1])
    }

    @Test
    func belowFloorPersistsDimmedDisplayKey() {
        let transport = FakeDDCTransport(lastReadLuminance: nil)
        let defaults = makeDefaults()
        let client = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: Self.candidate,
            defaults: defaults,
            gammaDimming: { _, _ in }
        )

        #expect(client.setBrightness(0.1) == true)
        let keys = defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) ?? []
        #expect(keys == ["0x10ac:0x437d:1112950348"])
    }

    @Test
    func risingAboveFloorClearsPersistedDimmedKey() {
        let transport = FakeDDCTransport(lastReadLuminance: nil)
        let defaults = makeDefaults()
        let client = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: Self.candidate,
            defaults: defaults,
            gammaDimming: { _, _ in }
        )

        #expect(client.setBrightness(0) == true)
        #expect(client.setBrightness(0.5) == true)
        let keys = defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) ?? []
        #expect(keys.isEmpty)
    }

    @Test
    func launchRestoresPersistedGammaThenClearsKeys() {
        let defaults = makeDefaults()
        let displayKey = "0x10ac:0x437d:1112950348"
        defaults.set([displayKey], forKey: AppStorageKeys.ddcSoftwareDimmedDisplays)

        var gammaCalls: [(displayID: CGDirectDisplayID, factor: Float)] = []
        _ = DDCBrightnessClient(
            transportProvider: { _ in nil },
            displayCandidateProvider: Self.candidate,
            defaults: defaults,
            gammaDimming: { gammaCalls.append((displayID: $0, factor: $1)) },
            activeExternalDisplays: { [displayKey: 42] }
        )

        let keys = defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) ?? []
        #expect(keys.isEmpty)
        #expect(gammaCalls.map(\.displayID) == [42])
        #expect(gammaCalls.map(\.factor) == [1])
    }

    @Test
    func switchingBetweenDisplaysKeepsBrightnessCachesIndependent() {
        let defaults = makeDefaults()
        let transport = FakeDDCTransport(lastReadLuminance: nil)
        var candidate = (displayID: CGDirectDisplayID(42), displayKey: "A")
        let client = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: { candidate },
            defaults: defaults,
            gammaDimming: { _, _ in }
        )

        #expect(client.setBrightness(0.5))
        candidate = (43, "B")
        #expect(client.setBrightness(0.875))
        candidate = (42, "A")
        #expect(client.currentBrightness() == 0.5)
        candidate = (43, "B")
        #expect(client.currentBrightness() == 0.875)
    }

    @Test
    func launchGammaRestoreUpdatesPersistedBrightness() {
        let defaults = makeDefaults()
        let key = "restored-display"
        defaults.set([key], forKey: AppStorageKeys.ddcSoftwareDimmedDisplays)
        defaults.set(Float(0), forKey: AppStorageKeys.ddcBrightnessCachePrefix + key)
        var gammaFactors: [Float] = []
        let client = DDCBrightnessClient(
            transportProvider: { _ in FakeDDCTransport(lastReadLuminance: nil) },
            displayCandidateProvider: { (42, key) },
            defaults: defaults,
            gammaDimming: { _, factor in gammaFactors.append(factor) },
            activeExternalDisplays: { [key: 42] }
        )

        #expect(gammaFactors == [1])
        #expect(client.currentBrightness() == 0.25)
        #expect(defaults.float(forKey: AppStorageKeys.ddcBrightnessCachePrefix + key) == 0.25)
        #expect(client.setBrightness(0.1875))
        #expect(gammaFactors == [1, 0.75])
    }

    @Test
    func terminationGammaRestoreUpdatesBrightnessCache() {
        let defaults = makeDefaults()
        let key = "terminated-display"
        let client = DDCBrightnessClient(
            transportProvider: { _ in FakeDDCTransport(lastReadLuminance: nil) },
            displayCandidateProvider: { (42, key) },
            defaults: defaults,
            gammaDimming: { _, _ in },
            activeExternalDisplays: { [key: 42] }
        )
        #expect(client.setBrightness(0))
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(client.currentBrightness() == 0.25)
        #expect(defaults.float(forKey: AppStorageKeys.ddcBrightnessCachePrefix + key) == 0.25)
    }

    @Test
    func disconnectedDisplayKeepsRecoveryStateUntilItReturns() {
        let defaults = makeDefaults()
        defaults.set(["online", "offline"], forKey: AppStorageKeys.ddcSoftwareDimmedDisplays)
        defaults.set(Float(0), forKey: AppStorageKeys.ddcBrightnessCachePrefix + "online")
        defaults.set(Float(0), forKey: AppStorageKeys.ddcBrightnessCachePrefix + "offline")
        var candidate: (displayID: CGDirectDisplayID, displayKey: String)?
        var restoredDisplays: [CGDirectDisplayID] = []
        let client = DDCBrightnessClient(
            transportProvider: { _ in FakeDDCTransport(lastReadLuminance: nil) },
            displayCandidateProvider: { candidate },
            defaults: defaults,
            gammaDimming: { id, _ in restoredDisplays.append(id) },
            activeExternalDisplays: { ["online": 42] }
        )
        #expect(restoredDisplays == [42])
        #expect(defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) == ["offline"])
        candidate = (43, "offline")
        #expect(client.currentBrightness() == 0.25)
        #expect(client.currentBrightness() == 0.25)
        #expect(restoredDisplays == [42, 43])
        #expect(defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) == nil)
    }

    @Test
    func terminatingWithDisconnectedDisplayPreservesItsRecoveryState() {
        let defaults = makeDefaults()
        var candidate: (displayID: CGDirectDisplayID, displayKey: String) = (42, "online")
        var gammaCalls: [(CGDirectDisplayID, Float)] = []
        let client = DDCBrightnessClient(
            transportProvider: { _ in FakeDDCTransport(lastReadLuminance: nil) },
            displayCandidateProvider: { candidate },
            defaults: defaults,
            gammaDimming: { gammaCalls.append(($0, $1)) },
            activeExternalDisplays: { ["online": 42] }
        )
        #expect(client.setBrightness(0))
        candidate = (43, "offline")
        #expect(client.setBrightness(0))
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(gammaCalls.map { $0.0 } == [42, 43, 42])
        #expect(gammaCalls.map { $0.1 } == [0, 0, 1])
        #expect(defaults.float(forKey: AppStorageKeys.ddcBrightnessCachePrefix + "online") == 0.25)
        #expect(defaults.float(forKey: AppStorageKeys.ddcBrightnessCachePrefix + "offline") == 0)
        #expect(defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) == ["offline"])
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "ddc-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}

@MainActor
private final class FakeDDCTransport: DDCI2CTransport {
    let lastReadLuminance: (current: Int, max: Int)?
    var writeResult = true
    var writeCallCount = 0
    var writtenValues: [UInt16] = []

    init(lastReadLuminance: (current: Int, max: Int)?) {
        self.lastReadLuminance = lastReadLuminance
    }

    func write(value: UInt16) -> Bool {
        writeCallCount += 1
        writtenValues.append(value)
        return writeResult
    }
}

// MARK: - Composite

@MainActor
struct CompositeBrightnessClientTests {
    @Test
    func prefersDisplayServicesWhenControllableDisplayExists() {
        let displayServices = FakeCompositeDisplayServices(hasControllable: true)
        displayServices.controllableDisplayIDs = [7]  // built-in panel
        let ddc = DDCBrightnessClient(
            transportProvider: { _ in FakeDDCTransport(lastReadLuminance: (current: 30, max: 100)) },
            displayCandidateProvider: { (displayID: 42, displayKey: "fake") },
            defaults: UserDefaults(suiteName: "composite-tests-\(UUID().uuidString)")!
        )
        let composite = CompositeBrightnessClient(
            displayServices: displayServices,
            ddc: ddc,
            activeDisplays: { [7] }
        )

        #expect(composite.currentBrightness() == 0.5)
        #expect(composite.setBrightness(0.9) == true)
        #expect(displayServices.targetedSetArguments[7] == [0.9])
    }

    @Test
    func fallsBackToDDCWhenDisplayServicesHasNothing() {
        // The clamshell case: no built-in panel, DisplayServices refuses externals.
        let displayServices = FakeCompositeDisplayServices(hasControllable: false)
        let transport = FakeDDCTransport(lastReadLuminance: (current: 50, max: 100))
        let ddc = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: { (displayID: 42, displayKey: "fake") },
            defaults: UserDefaults(suiteName: "composite-tests-\(UUID().uuidString)")!
        )
        let composite = CompositeBrightnessClient(
            displayServices: displayServices,
            ddc: ddc,
            activeDisplays: { [42] }
        )

        #expect(composite.currentBrightness() == 0.625)
        #expect(composite.setBrightness(0.5) == true)
        #expect(transport.writtenValues == [33])
        #expect(displayServices.setArguments.isEmpty)
    }

    @Test
    func sweepDrivesEveryDisplayMixedBackends() {
        // Bare brightness keys move all displays at once: the built-in panel
        // via DisplayServices and the DDC-only external in the same pass.
        let displayServices = FakeCompositeDisplayServices(hasControllable: true)
        displayServices.controllableDisplayIDs = [7]
        let transport = FakeDDCTransport(lastReadLuminance: nil)
        let ddc = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: { nil },
            defaults: UserDefaults(suiteName: "composite-tests-\(UUID().uuidString)")!
        )
        let composite = CompositeBrightnessClient(
            displayServices: displayServices,
            ddc: ddc,
            activeDisplays: { [7, 42] }
        )

        #expect(composite.setBrightness(0.625) == true)
        #expect(displayServices.targetedSetArguments[7] == [0.625])
        #expect(transport.writtenValues == [50])
    }

    // MARK: - Per-display routing (⇧+brightness)

    @Test
    func targetedRoutesDisplayServicesControllableDisplayToIt() {
        let displayServices = FakeCompositeDisplayServices(hasControllable: true)
        displayServices.controllableDisplayIDs = [7]  // built-in panel
        let ddc = DDCBrightnessClient(
            transportProvider: { _ in FakeDDCTransport(lastReadLuminance: (current: 30, max: 100)) },
            displayCandidateProvider: { (displayID: 42, displayKey: "fake") },
            defaults: UserDefaults(suiteName: "composite-tests-\(UUID().uuidString)")!
        )
        let composite = CompositeBrightnessClient(displayServices: displayServices, ddc: ddc)

        #expect(composite.currentBrightness(ofDisplay: 7) == 0.5)
        #expect(composite.setBrightness(0.9, ofDisplay: 7) == true)
        #expect(displayServices.targetedSetArguments[7] == [0.9])
    }

    @Test
    func targetedRoutesUncontrollableDisplayToDDC() {
        let displayServices = FakeCompositeDisplayServices(hasControllable: true)
        displayServices.controllableDisplayIDs = [7]  // built-in only, not the external
        let transport = FakeDDCTransport(lastReadLuminance: (current: 50, max: 100))
        let ddc = DDCBrightnessClient(
            transportProvider: { _ in transport },
            displayCandidateProvider: { (displayID: 42, displayKey: "fake") },
            defaults: UserDefaults(suiteName: "composite-tests-\(UUID().uuidString)")!
        )
        let composite = CompositeBrightnessClient(displayServices: displayServices, ddc: ddc)

        #expect(composite.currentBrightness(ofDisplay: 42) == 0.625)
        #expect(composite.setBrightness(0.5, ofDisplay: 42) == true)
        #expect(transport.writtenValues == [33])
        #expect(displayServices.targetedSetArguments[42] == nil)
    }
}

@MainActor
private final class FakeCompositeDisplayServices: DisplayServicesBrightnessControlling, DisplayServicesAvailabilityReporting, TargetedBrightnessControlling {
    let hasControllable: Bool
    /// Display IDs DisplayServices can drive directly; others go to DDC.
    var controllableDisplayIDs: Set<CGDirectDisplayID> = []
    var setArguments: [Float] = []
    var targetedSetArguments: [CGDirectDisplayID: [Float]] = [:]

    init(hasControllable: Bool) {
        self.hasControllable = hasControllable
    }

    func currentBrightness() -> Float? {
        hasControllable ? 0.5 : nil
    }

    func setBrightness(_ brightness: Float) -> Bool {
        setArguments.append(brightness)
        return hasControllable
    }

    func hasControllableDisplay() -> Bool {
        hasControllable
    }

    func canControl(displayID: CGDirectDisplayID) -> Bool {
        controllableDisplayIDs.contains(displayID)
    }

    func currentBrightness(ofDisplay displayID: CGDirectDisplayID) -> Float? {
        controllableDisplayIDs.contains(displayID) ? 0.5 : nil
    }

    func setBrightness(_ brightness: Float, ofDisplay displayID: CGDirectDisplayID) -> Bool {
        targetedSetArguments[displayID, default: []].append(brightness)
        return controllableDisplayIDs.contains(displayID)
    }
}
