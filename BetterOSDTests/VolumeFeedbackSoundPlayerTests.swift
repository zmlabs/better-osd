//
//  VolumeFeedbackSoundPlayerTests.swift
//  BetterOSDTests
//

import Foundation
@testable import BetterOSD
import Testing

@MainActor
struct VolumeFeedbackSoundPlayerTests {
    @Test
    func nilPreferenceMeansFeedbackDisabled() {
        #expect(VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(nil) == false)
    }

    @Test
    func boolPreferenceIsHonored() {
        #expect(VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(true) == true)
        #expect(VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(false) == false)
    }

    @Test
    func intPreferenceMatchesMacOSGlobalDomainStorage() {
        // macOS writes com.apple.sound.beep.feedback as Int 0/1, not Bool.
        // The old `as? Bool ?? true` path treated Int 0 as unset → always on.
        #expect(VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(1) == true)
        #expect(VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(0) == false)
    }

    @Test
    func nsNumberIntPreferenceIsHonored() {
        #expect(VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(NSNumber(value: 1)) == true)
        #expect(VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(NSNumber(value: 0)) == false)
    }

    @Test
    func userDefaultsIntZeroReadsAsDisabled() {
        let defaults = makeDefaults(feedback: 0)
        let stored = defaults.object(forKey: VolumeFeedbackSoundPlayer.feedbackPreferenceKey)
        #expect(VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(stored) == false)
    }

    @Test
    func invertPredicateUsesSameReader() {
        // playVolumeFeedback guards with `settingEnabled != invert`.
        // Setting off + no invert → skip; setting off + invert → play.
        #expect(shouldPlay(setting: 0, invert: false) == false)
        #expect(shouldPlay(setting: 0, invert: true) == true)
        // Setting on + no invert → play; setting on + invert → skip.
        #expect(shouldPlay(setting: 1, invert: false) == true)
        #expect(shouldPlay(setting: 1, invert: true) == false)
        #expect(shouldPlay(setting: nil, invert: false) == false)
        #expect(shouldPlay(setting: nil, invert: true) == true)
    }

    private func shouldPlay(setting: Int?, invert: Bool) -> Bool {
        let enabled = VolumeFeedbackSoundPlayer.isFeedbackSettingEnabled(setting)
        return enabled != invert
    }

    private func makeDefaults(feedback: Int?) -> UserDefaults {
        let suite = "volume-feedback-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let feedback {
            defaults.set(feedback, forKey: VolumeFeedbackSoundPlayer.feedbackPreferenceKey)
        }
        return defaults
    }
}
