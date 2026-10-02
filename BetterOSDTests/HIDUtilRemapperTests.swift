//
//  HIDUtilRemapperTests.swift
//  BetterOSDTests
//

@testable import BetterOSD
import Foundation
import os
import Testing

@MainActor
struct HIDUtilRemapperTests {
    private let thirdParty = HIDUtilRemapper.Entry(source: 0x700000039, destination: 0x700000029)

    @Test
    func addingOursPreservesThirdPartyMappings() {
        let merged = HIDUtilRemapper.mappingsByAddingOurs(to: [thirdParty])
        #expect(merged.contains(thirdParty))
        #expect(Set(merged.map(\.source)).isSuperset(of: HIDUtilRemapper.ownedSources))
        #expect(merged.count == 1 + HIDUtilRemapper.ownedEntries.count)
    }

    @Test
    func addingOursPreservesConflictingThirdPartyMapping() {
        let existing = HIDUtilRemapper.Entry(
            source: HIDUtilRemapper.f5Source,
            destination: 0x1
        )
        let merged = HIDUtilRemapper.mappingsByAddingOurs(to: [thirdParty, existing])
        let f5 = merged.filter { $0.source == HIDUtilRemapper.f5Source }
        #expect(f5.count == 1)
        #expect(f5.first == existing)
        #expect(merged.contains(thirdParty))
    }

    @Test
    func clearingRemovesOnlyOwnedEntries() {
        let existing = [thirdParty] + HIDUtilRemapper.ownedEntries
        let cleared = HIDUtilRemapper.mappingsByRemovingOurs(from: existing)
        #expect(cleared == [thirdParty])
    }

    @Test
    func clearingEmptyOwnedListIsNoOpForForeignMappings() {
        #expect(HIDUtilRemapper.mappingsByRemovingOurs(from: [thirdParty]) == [thirdParty])
        #expect(HIDUtilRemapper.mappingsByRemovingOurs(from: []) == [])
    }

    @Test
    func clearingPreservesThirdPartyMappingsWithOwnedSource() {
        let mapping = HIDUtilRemapper.Entry(source: HIDUtilRemapper.f5Source, destination: 0x700000029)
        #expect(HIDUtilRemapper.mappingsByRemovingOurs(from: [mapping]) == [mapping])
    }

    @Test
    func addingOursDoesNotDuplicateExistingOwnedMappings() {
        let mappings = [thirdParty] + HIDUtilRemapper.ownedEntries
        #expect(HIDUtilRemapper.mappingsByAddingOurs(to: mappings) == mappings)
    }

    @Test
    func emptyDeviceDoesNotOverwriteAnotherDevicesMappings() async {
        let transport = FakeHIDMappingTransport(devices: [
            .init(registryID: 1, entries: []),
            .init(registryID: 2, entries: [thirdParty]),
            .init(registryID: 3, entries: [thirdParty], isKeyboard: false),
        ])
        let controller = HIDRemappingController(transport: transport)
        controller.setEnabled(true, mode: "f5f6")
        await controller.waitForPendingUpdates()
        #expect(transport.entries(for: 1) == HIDUtilRemapper.ownedEntries)
        #expect(transport.entries(for: 2) == [thirdParty] + HIDUtilRemapper.ownedEntries)
        #expect(transport.entries(for: 3) == [thirdParty])
        controller.setEnabled(false, mode: "f5f6")
        await controller.waitForPendingUpdates()
        #expect(transport.entries(for: 1) == [])
        #expect(transport.entries(for: 2) == [thirdParty])
        #expect(transport.entries(for: 3) == [thirdParty])
    }

    @Test
    func disablingWaitsForAnInFlightEnable() async {
        let transport = FakeHIDMappingTransport(devices: [.init(registryID: 1, entries: [thirdParty])], pauseFirstRead: true)
        let controller = HIDRemappingController(transport: transport)
        controller.setEnabled(true, mode: "f5f6")
        #expect(transport.waitForFirstRead())
        controller.setEnabled(false, mode: "f5f6")
        transport.resumeFirstRead()
        await controller.waitForPendingUpdates()
        #expect(transport.writes.map(\.entries) == [[thirdParty] + HIDUtilRemapper.ownedEntries, [thirdParty]])
        #expect(transport.entries(for: 1) == [thirdParty])
    }

    @Test
    func reenablingSelectedF5F6ModeReappliesMappings() async {
        let transport = FakeHIDMappingTransport(devices: [.init(registryID: 1, entries: [])])
        let controller = HIDRemappingController(transport: transport)
        controller.setEnabled(true, mode: "f5f6")
        controller.setEnabled(false, mode: "f5f6")
        controller.setEnabled(true, mode: "f5f6")
        await controller.waitForPendingUpdates()
        #expect(transport.writes.map(\.entries) == [HIDUtilRemapper.ownedEntries, [], HIDUtilRemapper.ownedEntries])
        controller.setEnabled(true, mode: "cmdF1F2")
        await controller.waitForPendingUpdates()
        #expect(transport.entries(for: 1) == [])
    }

    @Test
    func unreadableMappingsAreNeverOverwritten() async {
        let transport = FakeHIDMappingTransport(devices: [.init(registryID: 1, entries: [thirdParty])], readSucceeds: false)
        let controller = HIDRemappingController(transport: transport)
        controller.setEnabled(true, mode: "f5f6")
        controller.setEnabled(false, mode: "f5f6")
        await controller.waitForPendingUpdates()
        #expect(transport.writes.isEmpty)
        #expect(transport.entries(for: 1) == [thirdParty])
    }

    @Test
    func decodeNativeMappingsPreservesFullWidthUsageCodes() {
        let rows = HIDUtilRemapper.ownedEntries.map {
            ["HIDKeyboardModifierMappingSrc": NSNumber(value: $0.source),
             "HIDKeyboardModifierMappingDst": NSNumber(value: $0.destination)]
        }
        #expect(IOHIDMappingTransport.decodeMappings(rows as NSArray) == HIDUtilRemapper.ownedEntries)
        #expect(IOHIDMappingTransport.decodeMappings(nil) == [])
        #expect(IOHIDMappingTransport.decodeMappings([] as NSArray) == [])
        #expect(IOHIDMappingTransport.decodeMappings([["HIDKeyboardModifierMappingSrc": NSNumber(value: 1)]]) == nil)
        #expect(IOHIDMappingTransport.decodeMappings("unreadable") == nil)
    }
}

nonisolated private final class FakeHIDMappingTransport: HIDMappingTransport {
    struct Write: Sendable {
        var registryID: UInt64
        var entries: [HIDUtilRemapper.Entry]
    }

    private struct State: Sendable {
        var devices: [HIDUtilRemapper.DeviceMappings]
        var writes: [Write] = []
        var readCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let readSucceeds: Bool
    private let pauseFirstRead: Bool
    private let firstReadStarted = DispatchSemaphore(value: 0)
    private let firstReadResume = DispatchSemaphore(value: 0)

    init(devices: [HIDUtilRemapper.DeviceMappings], readSucceeds: Bool = true, pauseFirstRead: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(devices: devices))
        self.readSucceeds = readSucceeds
        self.pauseFirstRead = pauseFirstRead
    }

    var writes: [Write] { state.withLock { $0.writes } }

    func entries(for registryID: UInt64) -> [HIDUtilRemapper.Entry]? {
        state.withLock { $0.devices.first { $0.registryID == registryID }?.entries }
    }

    func readMappings() -> [HIDUtilRemapper.DeviceMappings]? {
        let snapshot = state.withLock { state in
            state.readCount += 1
            return (devices: state.devices, isFirst: state.readCount == 1)
        }
        if pauseFirstRead && snapshot.isFirst {
            firstReadStarted.signal()
            _ = firstReadResume.wait(timeout: .now() + 5)
        }
        return readSucceeds ? snapshot.devices : nil
    }

    func writeMappings(_ entries: [HIDUtilRemapper.Entry], for registryID: UInt64) -> Bool {
        state.withLock { state in
            guard let index = state.devices.firstIndex(where: { $0.registryID == registryID }) else { return false }
            state.devices[index].entries = entries
            state.writes.append(Write(registryID: registryID, entries: entries))
            return true
        }
    }

    func waitForFirstRead() -> Bool {
        firstReadStarted.wait(timeout: .now() + 5) == .success
    }

    func resumeFirstRead() {
        firstReadResume.signal()
    }
}
