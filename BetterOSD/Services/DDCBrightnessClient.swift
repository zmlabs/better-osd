//
//  DDCBrightnessClient.swift
//  BetterOSD
//
//  Controls brightness of external displays over DDC/CI (VCP code 0x10) via
//  IOKit's IOAVService transport — the same channel macOS itself uses on
//  Apple Silicon. Needed because DisplayServices.framework only supports
//  built-in panels: with the lid closed (clamshell) it reports no controllable
//  display, which used to make F1/F2 fall through to the system OSD.
//
//  Byte format follows m1ddc (waydabber/m1ddc), field-proven across monitors:
//    write: [0x84, 0x03, vcp, valueHi, valueLo, checksum]  checksum = 0x6e ^ 0x51 ^ b0..b4
//    read:  [0x82, 0x01, vcp, checksum] → reply[6..7] = max, reply[8..9] = current
//
//  DDC reads are unreliable on some setups (e.g. Dell monitors while Dell
//  Display Manager is running answer with garbage), so the client keeps a
//  per-display cache of the last written value, persisted in UserDefaults.
//
//  NOTE: all methods must be called on the main thread (they are invoked from
//  the CGEventTap on the main run loop). DDC I/O includes ~10 ms pacing sleeps.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit

// MARK: - Transport

/// Raw I2C read/write against a display's DCPAVServiceProxy.
/// Abstracted so unit tests can fake the wire.
protocol DDCI2CTransport: AnyObject {
    /// Last known VCP 0x10 reply, sanity-checked. Nil when the display
    /// never answered a sane read (e.g. Dell Display Manager locks reads).
    var lastReadLuminance: (current: Int, max: Int)? { get }
    func write(value: UInt16) -> Bool
}

/// Resolves the transport for a given display. Returns nil when the display
/// has no external DCPAVServiceProxy (built-in panel, virtual display, …).
typealias DDCTransportProvider = (CGDirectDisplayID) -> DDCI2CTransport?

/// Picks the external display to control. Injectable for tests.
typealias DDCDisplayCandidateProvider = () -> (displayID: CGDirectDisplayID, displayKey: String)?

/// Applies (or, with factor 1, removes) software gamma dimming for one
/// display. Injectable so unit tests can fake the gamma tables.
typealias GammaDimmingApplier = (CGDirectDisplayID, Float) -> Void

/// Resolves currently attached external displays by stable display key.
typealias DDCActiveExternalDisplaysProvider = () -> [String: CGDirectDisplayID]

// MARK: - Client

final class DDCBrightnessClient: DisplayServicesBrightnessControlling, TargetedBrightnessControlling {
    /// Assumed brightness when nothing is cached and the display won't answer
    /// reads. The very first key press steps from here; every successful write
    /// afterwards re-seeds the cache with the real value.
    private static let assumedBrightness: Float = 0.75
    private static let vcpLuminance: UInt8 = 0x10

    /// DDC 0 is not "off": panels clamp their backlight at a floor (the Dell
    /// this was field-tested on still glows at ~25%). Below this point the
    /// write pins DDC at 0 and the rest of the range is covered by software
    /// gamma dimming — the same trick MonitorControl uses — so brightness 0
    /// is truly black.
    private static let softwareDimmingFloor: Float = 0.25

    private let transportProvider: DDCTransportProvider
    private let displayCandidateProvider: DDCDisplayCandidateProvider
    private let defaults: UserDefaults
    private let gammaDimming: GammaDimmingApplier
    private let activeExternalDisplays: DDCActiveExternalDisplaysProvider

    private var cachedTransport: DDCI2CTransport?
    private var cachedDisplayID: CGDirectDisplayID?
    private var cachedBrightness: [String: Float] = [:]
    /// Displays currently dimmed via gamma tables, so we restore them once
    /// (not on every above-floor write) and on termination.
    private var softwareDimmedDisplays: Set<String> = []
    private var pendingGammaRestores: Set<String>
    private var terminationObserver: (any NSObjectProtocol)?

    init(
        transportProvider: @escaping DDCTransportProvider = IOKitDDCTransport.resolve,
        displayCandidateProvider: @escaping DDCDisplayCandidateProvider = DDCBrightnessClient.externalDisplayCandidate,
        defaults: UserDefaults = .standard,
        gammaDimming: @escaping GammaDimmingApplier = DDCBrightnessClient.applyGammaDimming,
        activeExternalDisplays: @escaping DDCActiveExternalDisplaysProvider = DDCBrightnessClient.activeExternalDisplaysByKey
    ) {
        self.transportProvider = transportProvider
        self.displayCandidateProvider = displayCandidateProvider
        self.defaults = defaults
        self.gammaDimming = gammaDimming
        self.activeExternalDisplays = activeExternalDisplays
        pendingGammaRestores = Set(defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) ?? [])

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreGammaForTermination()
            }
        }

        // If a previous run dimmed gamma and exited without willTerminate
        // (force-quit, crash), restore those displays now so launch never
        // leaves the screen stuck dark.
        restorePersistedGammaIfNeeded()
    }

    func currentBrightness() -> Float? {
        guard let (displayID, key) = displayCandidateProvider() else {
            return nil
        }
        return currentBrightness(displayID: displayID, displayKey: key)
    }

    func setBrightness(_ brightness: Float) -> Bool {
        guard let (displayID, key) = displayCandidateProvider() else {
            return false
        }
        return setBrightness(brightness, displayID: displayID, displayKey: key)
    }

    // MARK: - Per-display control (⇧+brightness path)

    func currentBrightness(ofDisplay displayID: CGDirectDisplayID) -> Float? {
        currentBrightness(displayID: displayID, displayKey: Self.displayKey(for: displayID))
    }

    func setBrightness(_ brightness: Float, ofDisplay displayID: CGDirectDisplayID) -> Bool {
        setBrightness(brightness, displayID: displayID, displayKey: Self.displayKey(for: displayID))
    }

    // MARK: - Shared read/write

    private func currentBrightness(displayID: CGDirectDisplayID, displayKey key: String) -> Float? {
        restorePendingGamma(displayID: displayID, key: key)
        if let cached = storedBrightness(for: key) {
            return cached
        }

        guard let transport = transport(for: displayID) else { return nil }

        if let read = transport.lastReadLuminance, read.max > 0 {
            // Invert the software-dimming split: the panel's DDC range only
            // covers [floor … 1] of our brightness domain.
            let raw = max(0, min(1, Float(read.current) / Float(read.max)))
            let normalized = Self.softwareDimmingFloor + raw * (1 - Self.softwareDimmingFloor)
            cache(normalized, for: key)
            return normalized
        }

        // Reads are best-effort: on displays that answer with garbage
        // (DDM-locked Dells, some KVMs) step from an assumed level instead.
        // It is deliberately NOT cached — the next successful write replaces
        // it with the real level.
        return Self.assumedBrightness
    }

    private func setBrightness(_ brightness: Float, displayID: CGDirectDisplayID, displayKey key: String) -> Bool {
        restorePendingGamma(displayID: displayID, key: key)
        guard let transport = transport(for: displayID) else {
            return false
        }

        let clamped = max(0, min(1, brightness))
        let maxValue = Float(transport.lastReadLuminance?.max ?? 100)

        // Above the floor DDC covers the range. Below it DDC pins at 0 (the
        // panel's backlight floor) and the gamma tables dim the content the
        // rest of the way to true black.
        let hardwareFraction: Float
        var gammaFactor: Float?
        if clamped >= Self.softwareDimmingFloor {
            hardwareFraction = (clamped - Self.softwareDimmingFloor) / (1 - Self.softwareDimmingFloor)
        } else {
            hardwareFraction = 0
            gammaFactor = clamped / Self.softwareDimmingFloor
        }
        let value = UInt16((maxValue * hardwareFraction).rounded())

        guard transport.write(value: value) else {
            invalidateTransport()
            return false
        }

        if let gammaFactor {
            gammaDimming(displayID, gammaFactor)
            markSoftwareDimmed(key: key)
        } else if softwareDimmedDisplays.remove(key) != nil {
            gammaDimming(displayID, 1)
            unmarkSoftwareDimmed(key: key)
        }

        cache(clamped, for: key)
        return true
    }

    // MARK: - Software dimming

    /// Leaving the gamma tables dimmed after quit would keep the screen dark
    /// content-wise, so restore every display we touched on the way out.
    private func restoreGammaForTermination() {
        let active = activeExternalDisplays()
        let keys = softwareDimmedDisplays.union(pendingGammaRestores)
        for key in keys {
            guard let displayID = active[key] else { continue }
            restoreGamma(displayID: displayID, key: key)
        }
        softwareDimmedDisplays.removeAll()
    }

    private func restorePersistedGammaIfNeeded() {
        guard !pendingGammaRestores.isEmpty else { return }
        let active = activeExternalDisplays()
        for key in pendingGammaRestores {
            if let displayID = active[key] {
                restoreGamma(displayID: displayID, key: key)
            }
        }
    }

    private func restorePendingGamma(displayID: CGDirectDisplayID, key: String) {
        guard pendingGammaRestores.contains(key) else { return }
        restoreGamma(displayID: displayID, key: key)
    }

    private func restoreGamma(displayID: CGDirectDisplayID, key: String) {
        gammaDimming(displayID, 1)
        cache(max(Self.softwareDimmingFloor, storedBrightness(for: key) ?? Self.softwareDimmingFloor), for: key)
        pendingGammaRestores.remove(key)
        unmarkSoftwareDimmed(key: key)
    }

    private func markSoftwareDimmed(key: String) {
        softwareDimmedDisplays.insert(key)
        var keys = Set(defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) ?? [])
        keys.insert(key)
        defaults.set(Array(keys), forKey: AppStorageKeys.ddcSoftwareDimmedDisplays)
    }

    private func unmarkSoftwareDimmed(key: String) {
        var keys = Set(defaults.stringArray(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays) ?? [])
        keys.remove(key)
        if keys.isEmpty {
            defaults.removeObject(forKey: AppStorageKeys.ddcSoftwareDimmedDisplays)
        } else {
            defaults.set(Array(keys), forKey: AppStorageKeys.ddcSoftwareDimmedDisplays)
        }
    }

    /// Active non-builtin displays keyed by `displayKey(for:)`.
    nonisolated private static func activeExternalDisplaysByKey() -> [String: CGDirectDisplayID] {
        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeCount)
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(activeCount))
        guard CGGetActiveDisplayList(activeCount, &displays, &activeCount) == .success else {
            return [:]
        }

        var result: [String: CGDirectDisplayID] = [:]
        for id in displays where CGDisplayIsBuiltin(id) == 0 {
            result[displayKey(for: id)] = id
        }
        return result
    }

    /// Scales the gamma tables linearly: out = factor × in. Factor 1 is the
    /// identity restore (same tradeoff as f.lux/MonitorControl: while dimmed,
    /// custom color profiles are overridden).
    nonisolated private static func applyGammaDimming(displayID: CGDirectDisplayID, factor: Float) {
        let clamped = CGGammaValue(max(0, min(1, factor)))
        CGSetDisplayTransferByFormula(
            displayID,
            0, clamped, 1,
            0, clamped, 1,
            0, clamped, 1
        )
    }

    // MARK: - Transport caching

    private func transport(for displayID: CGDirectDisplayID) -> DDCI2CTransport? {
        if let cachedTransport, cachedDisplayID == displayID {
            return cachedTransport
        }

        guard let resolved = transportProvider(displayID) else {
            invalidateTransport()
            return nil
        }

        cachedTransport = resolved
        cachedDisplayID = displayID
        return resolved
    }

    private func invalidateTransport() {
        cachedTransport = nil
        cachedDisplayID = nil
    }

    // MARK: - Brightness cache

    private static func cacheKey(displayKey: String) -> String {
        AppStorageKeys.ddcBrightnessCachePrefix + displayKey
    }

    private func storedBrightness(for displayKey: String) -> Float? {
        if let cached = cachedBrightness[displayKey] {
            return cached
        }
        let key = Self.cacheKey(displayKey: displayKey)
        guard let stored = defaults.object(forKey: key) as? Float else { return nil }
        cachedBrightness[displayKey] = stored
        return stored
    }

    private func cache(_ brightness: Float, for displayKey: String) {
        cachedBrightness[displayKey] = brightness
        defaults.set(brightness, forKey: Self.cacheKey(displayKey: displayKey))
    }

    // MARK: - Display selection

    /// The external display brightness keys should target: the main display
    /// when it is external (the clamshell case), otherwise the first
    /// non-builtin active display.
    nonisolated static func externalDisplayCandidate() -> (displayID: CGDirectDisplayID, displayKey: String)? {
        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeCount)
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(activeCount))
        guard CGGetActiveDisplayList(activeCount, &displays, &activeCount) == .success else {
            return nil
        }

        let mainID = CGMainDisplayID()
        let candidate = (displays.contains(mainID) && CGDisplayIsBuiltin(mainID) == 0)
            ? mainID
            : displays.first { CGDisplayIsBuiltin($0) == 0 }

        guard let id = candidate else { return nil }
        return (id, Self.displayKey(for: id))
    }

    /// Stable cache key for a display, matching externalDisplayCandidate's.
    nonisolated static func displayKey(for id: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(id)):\(CGDisplayModelNumber(id)):\(CGDisplaySerialNumber(id))"
    }
}

// MARK: - IOKit implementation

/// DDC/CI over IOAVService, mirroring m1ddc's registry matching:
/// display → IODisplayLocation → IOMobileFramebuffer → its DCPAVServiceProxy
/// with Location == "External" → IOAVServiceCreateWithService.
nonisolated final class IOKitDDCTransport: DDCI2CTransport {
    private typealias AVServiceCreateWithService = @convention(c) (CFAllocator?, io_service_t) -> CFTypeRef?
    private typealias ReadI2C = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
    private typealias WriteI2C = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeRawPointer, UInt32) -> Int32
    private typealias CreateInfoDictionary = @convention(c) (CGDirectDisplayID) -> CFDictionary?

    private static let chipAddressDefault: UInt32 = 0x37
    private static let chipAddressMCDP29XX: UInt32 = 0xB7
    private static let inputAddress: UInt32 = 0x51
    private static let writeIterations = 2
    private static let settleMicroseconds: useconds_t = 10_000

    private let service: CFTypeRef
    private let chipAddress: UInt32
    let lastReadLuminance: (current: Int, max: Int)?

    private static let createWithService: AVServiceCreateWithService? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        return load(handle: iokit, symbol: "IOAVServiceCreateWithService")
    }()

    private static func load<T>(handle: UnsafeMutableRawPointer, symbol: String) -> T? {
        guard let pointer = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private init(service: CFTypeRef, chipAddress: UInt32, lastReadLuminance: (current: Int, max: Int)?) {
        self.service = service
        self.chipAddress = chipAddress
        self.lastReadLuminance = lastReadLuminance
    }

    static func resolve(displayID: CGDirectDisplayID) -> DDCI2CTransport? {
        guard let create = createWithService,
              let adapter = adapterEntry(for: displayID)
        else { return nil }

        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(1), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var framebufferMatches = false
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(entry) }

            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                var entryID: UInt64 = 0
                framebufferMatches = IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS
                    && entryID == adapter.registryEntryID
                continue
            }

            guard framebufferMatches, registryEntryName(entry) == "DCPAVServiceProxy" else { continue }
            guard registryStringProperty(entry, "Location") == "External" else { continue }

            let chipAddress = isMCDP29XX(entry) ? chipAddressMCDP29XX : chipAddressDefault
            guard let service = create(kCFAllocatorDefault, entry) else { continue }

            let read = readLuminance(service: service, chipAddress: chipAddress)
            return IOKitDDCTransport(service: service, chipAddress: chipAddress, lastReadLuminance: read)
        }

        return nil
    }

    // MARK: - Registry matching

    private struct AdapterEntry {
        var registryEntryID: UInt64
    }

    private static func adapterEntry(for displayID: CGDirectDisplayID) -> AdapterEntry? {
        guard let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW),
              let createInfo: CreateInfoDictionary = load(handle: coreDisplay, symbol: "CoreDisplay_DisplayCreateInfoDictionary"),
              let info = createInfo(displayID),
              let location = (info as NSDictionary)["IODisplayLocation"] as? String
        else { return nil }

        let entry = IORegistryEntryCopyFromPath(kIOMainPortDefault, location as CFString)
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }

        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS else { return nil }
        return AdapterEntry(registryEntryID: entryID)
    }

    private static func registryEntryName(_ entry: io_object_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        return buffer.withUnsafeMutableBufferPointer { buf -> String in
            IORegistryEntryGetName(entry, buf.baseAddress)
            return String(cString: buf.baseAddress!)
        }
    }

    private static func registryStringProperty(_ entry: io_object_t, _ key: String) -> String? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault, 0) as? String
    }

    private static func isMCDP29XX(_ entry: io_object_t) -> Bool {
        var parent = io_registry_entry_t()
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }

        return registryStringProperty(parent, "EPICProviderClass") == "AppleDCPMCDP29XX"
    }

    // MARK: - DDC/CI

    /// One-shot luminance read performed while resolving. Sanity-checked:
    /// garbage replies (Dell Display Manager locks reads) return nil.
    private static func readLuminance(service: CFTypeRef, chipAddress: UInt32) -> (current: Int, max: Int)? {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let read: ReadI2C = load(handle: iokit, symbol: "IOAVServiceReadI2C")
        else { return nil }

        return readLuminance(
            writeRequest: { writePacket($0, service: service, chipAddress: chipAddress) },
            readReply: {
                var reply = [UInt8](repeating: 0, count: 12)
                let pointer = Unmanaged.passUnretained(service).toOpaque()
                guard read(pointer, chipAddress, inputAddress, &reply, 12) == 0 else { return nil }
                return reply
            },
            waitForReply: { usleep(chipAddress == chipAddressMCDP29XX ? 50_000 : settleMicroseconds) }
        )
    }

    static func readLuminance(
        writeRequest: ([UInt8]) -> Bool,
        readReply: () -> [UInt8]?,
        waitForReply: () -> Void
    ) -> (current: Int, max: Int)? {
        var request: [UInt8] = [0x82, 0x01, 0x10, 0]
        request[3] = 0x6e ^ request[0] ^ request[1] ^ request[2]
        guard writeRequest(request) else { return nil }
        waitForReply()
        guard let reply = readReply(), reply.count >= 11,
              reply[0] == 0x6e, reply[1] == 0x88, reply[2] == 0x02,
              reply[3] == 0, reply[4] == 0x10,
              reply.prefix(11).reduce(UInt8(0x50), ^) == 0
        else { return nil }
        let maxValue = (Int(reply[6]) << 8) | Int(reply[7])
        let currentValue = (Int(reply[8]) << 8) | Int(reply[9])
        guard maxValue > 0, maxValue <= 1000, currentValue <= maxValue else { return nil }
        return (currentValue, maxValue)
    }

    func write(value: UInt16) -> Bool {
        var packet: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = 0x6e ^ 0x51 ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4]
        return Self.writePacket(packet, service: service, chipAddress: chipAddress)
    }

    private static func writePacket(_ packet: [UInt8], service: CFTypeRef, chipAddress: UInt32) -> Bool {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let write: WriteI2C = load(handle: iokit, symbol: "IOAVServiceWriteI2C")
        else { return false }
        let pointer = Unmanaged.passUnretained(service).toOpaque()
        for _ in 0 ..< writeIterations {
            usleep(settleMicroseconds)
            if write(pointer, chipAddress, inputAddress, packet, UInt32(packet.count)) != 0 {
                return false
            }
        }
        return true
    }
}
