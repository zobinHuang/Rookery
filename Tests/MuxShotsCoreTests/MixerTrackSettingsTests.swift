import Foundation
import MuxShotsCore
import Testing

struct MixerTrackSettingsTests {
    @Test func freshSettingsAreNeutral() {
        #expect(MixerTrackSettings().isNeutral)
    }

    @Test func takingOverAloneKeepsSettingsNeutral() {
        var settings = MixerTrackSettings()
        settings.isTakenOver = true

        #expect(settings.isNeutral)
    }

    @Test func anyChangeToTheSoundIsNotNeutral() {
        var settings = MixerTrackSettings()
        settings.listEqualizerGains[3] = 4

        #expect(!settings.isNeutral)
    }

    @Test func clampingBringsValuesIntoRange() {
        var settings = MixerTrackSettings()
        settings.volume = 9
        settings.pan = -3
        settings.width = -1
        settings.reverbMix = 400
        settings.listEqualizerGains = [30, -30]

        let clamped = settings.clamped

        #expect(clamped.volume == 2)
        #expect(clamped.pan == -1)
        #expect(clamped.width == 0)
        #expect(clamped.reverbMix == 100)
        #expect(clamped.listEqualizerGains.count == MixerTrackSettings.listEqualizerFrequencies.count)
        #expect(clamped.listEqualizerGains.prefix(3) == [12, -12, 0])
    }

    @Test func settingsSavedBeforeMutingExistedStillLoad() throws {
        let json = #"{"isTakenOver":true,"volume":0.5}"#

        let settings = try JSONDecoder().decode(MixerTrackSettings.self, from: Data(json.utf8))

        #expect(settings.isTakenOver)
        #expect(settings.volume == 0.5)
        #expect(!settings.isMuted)
        #expect(settings.listEqualizerGains.count == MixerTrackSettings.listEqualizerFrequencies.count)
    }

    @Test func mutingWithoutTakingOverSilencesButDoesNotTreat() {
        var settings = MixerTrackSettings()
        settings.isMuted = true
        settings.volume = 0.3

        #expect(settings.isCaptureNeeded)
        #expect(settings.effective.isMuted)
        #expect(settings.effective.volume == 1)
    }
}
