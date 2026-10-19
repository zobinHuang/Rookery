import Foundation
import MuxShotsControl
import MuxShotsCore
import Testing

struct BrowserProtocolTests {
    @Test func decodesTheExtensionsTabList() throws {
        let json = """
            {"type":"tabs","list_tabs":[{"tab_id":7,"window_id":2,"title":"Lofi","url":"https://example.com/",\
            "fav_icon_url":null,"is_audible":true,"mode":"page"}]}
            """

        let event = try BrowserWire.makeDecoder().decode(BrowserEvent.self, from: Data(json.utf8))

        #expect(event == .tabs(listTabs: [BrowserTab(
            tabId: 7,
            windowId: 2,
            title: "Lofi",
            url: "https://example.com/",
            favIconUrl: nil,
            isAudible: true,
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
}
