import Foundation
import IOKit.hidsystem

nonisolated enum HIDUtilRemapper {
    static let f5Source: UInt64 = 0xC000000CF
    static let f5Destination: UInt64 = 0xFF00000009
    static let f6Source: UInt64 = 0x10000009B
    static let f6Destination: UInt64 = 0xFF00000008
    static let ownedSources: Set<UInt64> = [f5Source, f6Source]

    struct Entry: Equatable, Sendable {
        var source: UInt64
        var destination: UInt64
    }

    struct DeviceMappings: Sendable {
        var registryID: UInt64
        var entries: [Entry]
        var isKeyboard: Bool = true
    }

    static let ownedEntries: [Entry] = [
        Entry(source: f5Source, destination: f5Destination),
        Entry(source: f6Source, destination: f6Destination),
    ]

    static let controller = HIDRemappingController()

    static func mappingsByAddingOurs(to existing: [Entry]) -> [Entry] {
        let sources = Set(existing.map(\.source))
        return existing + ownedEntries.filter { !sources.contains($0.source) }
    }

    static func mappingsByRemovingOurs(from existing: [Entry]) -> [Entry] {
        existing.filter { !ownedEntries.contains($0) }
    }

    static func setEnabled(_ enabled: Bool, mode: String) {
        controller.setEnabled(enabled, mode: mode)
    }
}

nonisolated protocol HIDMappingTransport: Sendable {
    func readMappings() -> [HIDUtilRemapper.DeviceMappings]?
    func writeMappings(_ entries: [HIDUtilRemapper.Entry], for registryID: UInt64) -> Bool
}

nonisolated final class HIDRemappingController: Sendable {
    private let transport: any HIDMappingTransport
    private let queue = DispatchQueue(label: "dev.zhangyu.better-osd.key-remapping", qos: .userInitiated)

    init(transport: any HIDMappingTransport = IOHIDMappingTransport()) {
        self.transport = transport
    }

    func setEnabled(_ enabled: Bool, mode: String) {
        let shouldApply = enabled && mode == "f5f6"
        queue.async { [transport] in
            guard let devices = transport.readMappings() else { return }
            for device in devices {
                if shouldApply && !device.isKeyboard { continue }
                let next = shouldApply
                    ? HIDUtilRemapper.mappingsByAddingOurs(to: device.entries)
                    : HIDUtilRemapper.mappingsByRemovingOurs(from: device.entries)
                guard next != device.entries else { continue }
                _ = transport.writeMappings(next, for: device.registryID)
            }
        }
    }

    func waitForPendingUpdates() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

nonisolated struct IOHIDMappingTransport: HIDMappingTransport {
    private static let propertyKey = "UserKeyMapping"
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"

    func readMappings() -> [HIDUtilRemapper.DeviceMappings]? {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return nil }
        return services.compactMap { service in
            guard let id = IOHIDServiceClientGetRegistryID(service) as? NSNumber,
                  let entries = Self.decodeMappings(IOHIDServiceClientCopyProperty(service, Self.propertyKey as CFString))
            else { return nil }
            return HIDUtilRemapper.DeviceMappings(
                registryID: id.uint64Value,
                entries: entries,
                isKeyboard: IOHIDServiceClientConformsTo(service, 1, 6) != 0
            )
        }
    }

    func writeMappings(_ entries: [HIDUtilRemapper.Entry], for registryID: UInt64) -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient],
              let service = services.first(where: {
                  (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value == registryID
              })
        else { return false }
        let rows = entries.map {
            [Self.sourceKey: NSNumber(value: $0.source), Self.destinationKey: NSNumber(value: $0.destination)]
        }
        return IOHIDServiceClientSetProperty(service, Self.propertyKey as CFString, rows as CFArray)
    }

    static func decodeMappings(_ value: Any?) -> [HIDUtilRemapper.Entry]? {
        guard let value else { return [] }
        guard let rows = value as? [[String: NSNumber]] else { return nil }
        var entries: [HIDUtilRemapper.Entry] = []
        for row in rows {
            guard let source = row[sourceKey], let destination = row[destinationKey] else { return nil }
            entries.append(HIDUtilRemapper.Entry(source: source.uint64Value, destination: destination.uint64Value))
        }
        return entries
    }
}
