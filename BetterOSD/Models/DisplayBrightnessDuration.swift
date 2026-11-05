import Foundation

enum DisplayBrightnessDuration: Int, CaseIterable, Identifiable {
    case instant = 0
    case quarterSecond = 250
    case halfSecond = 500
    case oneSecond = 1000
    case twoSeconds = 2000

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) / 1000 }

    var displayName: LocalizedStringResource {
        switch self {
        case .instant: "0 s (Instant)"
        case .quarterSecond: "0.25 s"
        case .halfSecond: "0.5 s"
        case .oneSecond: "1 s"
        case .twoSeconds: "2 s"
        }
    }

    static func selected(in preferences: UserDefaults) -> Self {
        let stored = preferences.object(forKey: AppStorageKeys.displayBrightnessDurationMs) as? Int
        // Earlier local builds offered 3 seconds. Use the nearest remaining option.
        if stored == 3000 { return .twoSeconds }
        return stored.flatMap(Self.init(rawValue:)) ?? .oneSecond
    }
}
