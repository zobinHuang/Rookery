import Foundation
import MuxShotsControl
import MuxShotsCore
import Testing

struct BrowserProtocolTests {
    @Test func decodesTheExtensionsTabList() throws {
        let json = """
            {"type":"tabs","list_tabs":[{"tab_id":7,"window_id":2,"title":"Lofi","url":"https://example.com/",\
            "fav_icon_url":null,"is_audible":true,"is_muted":false,"mode":"page"}]}
            """

        let event = try BrowserWire.makeDecoder().decode(BrowserEvent.self, from: Data(json.utf8))

        #expect(event == .tabs(listTabs: [BrowserTab(
            tabId: 7,
            windowId: 2,
            title: "Lofi",
            url: "https://example.com/",
            favIconUrl: nil,
            isAudible: true,
            isMuted: false,
            mode: .page
        )]))
    }

    @Test func encodesSettingsInTheExtensionsSpelling() throws {
        var settings = MixerTrackSettings()
        settings.isTakenOver = true

        let data = try BrowserWire.makeEncoder().encode(BrowserCommand.apply(tabId: 7, settings: settings))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedSettings = try #require(object["settings"] as? [String: Any])

        #expect(object["type"] as? String == "apply")
        #expect(object["tab_id"] as? Int == 7)
        #expect(encodedSettings["is_taken_over"] as? Bool == true)
        #expect(encodedSettings["list_equalizer_gains"] is [Any])
    }

    @Test func readsTabsFromAnExtensionThatPredatesMuting() throws {
        let json = #"{"tab_id":7,"window_id":2,"title":"t","url":"u","is_audible":true,"mode":"idle"}"#

        let tab = try BrowserWire.makeDecoder().decode(BrowserTab.self, from: Data(json.utf8))

        #expect(!tab.isMuted)
        #expect(tab.favIconUrl == nil)
    }

    @Test func readsTheSettingsTheExtensionKeptForATab() throws {
        let json = #"{"tab_id":7,"window_id":2,"title":"t","url":"u","is_audible":true,"is_muted":true,"mode":"page","settings":{"is_taken_over":true,"is_muted":true,"volume":0.5}}"#

        let tab = try BrowserWire.makeDecoder().decode(BrowserTab.self, from: Data(json.utf8))

        #expect(tab.settings?.isTakenOver == true)
        #expect(tab.settings?.volume == 0.5)
        #expect(tab.settings?.isMuted == true)
    }

    @Test func greetsTheExtensionWithAHello() throws {
        let data = try BrowserWire.makeEncoder().encode(BrowserCommand.hello)

        #expect(String(decoding: data, as: UTF8.self) == #"{"type":"hello"}"#)
    }
}
