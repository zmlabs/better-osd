import Foundation

enum DisplayBrightnessDuration: Int, CaseIterable, Identifiable {
    case instant = 0
    case quarterSecond = 250
    case halfSecond = 500
    case oneSecond = 1000
    case twoSeconds = 2000
    case threeSeconds = 3000

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) / 1000 }

    var label: String {
        switch self {
        case .instant: "0 s"
        case .quarterSecond: "0.25 s"
        case .halfSecond: "0.5 s"
        case .oneSecond: "1 s"
        case .twoSeconds: "2 s"
        case .threeSeconds: "3 s"
        }
    }

    static func selected(in preferences: UserDefaults) -> Self {
        let stored = preferences.object(forKey: AppStorageKeys.displayBrightnessDurationMs) as? Int
        return stored.flatMap(Self.init(rawValue:)) ?? .oneSecond
    }
}
