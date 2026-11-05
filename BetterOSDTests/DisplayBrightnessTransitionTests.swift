import Foundation
@testable import BetterOSD
import Testing

@MainActor
struct DisplayBrightnessTransitionTests {
    @Test(arguments: [0.25, 0.5, 1.0, 2.0, 3.0])
    func reachesTargetAtSelectedDuration(duration: TimeInterval) {
        let transition = DisplayBrightnessTransition(start: 0.25, target: 0.75, startedAt: 10, duration: duration)

        #expect(transition.value(at: 10) == 0.25)
        #expect(transition.value(at: 10 + duration / 2) == 0.5)
        #expect(transition.value(at: 10 + duration) == 0.75)
        #expect(transition.value(at: 11 + duration) == 0.75)
        #expect(transition.isFinished(at: 10 + duration / 2) == false)
        #expect(transition.isFinished(at: 10 + duration) == true)
    }

    @Test
    func durationOptionsMatchSettingsChoices() {
        #expect(DisplayBrightnessDuration.allCases.map(\.rawValue) == [0, 250, 500, 1000, 2000, 3000])
        #expect(DisplayBrightnessDuration.instant.seconds == 0)
        #expect(DisplayBrightnessDuration.oneSecond.seconds == 1)
    }

    @Test
    func persistedDurationDefaultsToOneSecondAndAcceptsOnlyListedValues() {
        let suiteName = "BetterOSDTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }

        #expect(DisplayBrightnessDuration.selected(in: preferences) == .oneSecond)

        preferences.set(0, forKey: AppStorageKeys.displayBrightnessDurationMs)
        #expect(DisplayBrightnessDuration.selected(in: preferences) == .instant)

        preferences.set(2500, forKey: AppStorageKeys.displayBrightnessDurationMs)
        #expect(DisplayBrightnessDuration.selected(in: preferences) == .oneSecond)
    }
}
