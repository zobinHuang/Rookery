# Chrome extension

The extension in `extensions/chrome` lets the mixer treat Chrome tabs one by one and shows tabs' videos in the sidebar. Rookery cannot do either from outside: all of Chrome's tabs play through one audio service process, and a background tab's video is never on screen.

## Parts

| File | Runs in | Does |
|---|---|---|
| `background.ts` (`MixerBridge`) | Service worker | Connects to the app through native messaging, reports tabs and levels, carries settings, mute, capture and video commands, keeps per-tab settings in `chrome.storage.session`. |
| `content.ts` (`PageMixer`) | Every frame of every page | Routes the page's `<audio>`/`<video>` elements through a track of its own once the tab is taken over, reports the frame's state, levels and largest video. |
| `page-picture.ts` (`PagePicture`) | Content script | Streams the frame's largest video to the app over WebRTC. |
| `offscreen.ts` (`CaptureMixer`) | Offscreen document | Plays whole-tab captures, for tabs whose page cannot be processed, through tracks of its own. |
| `track-graph.ts` (`TrackGraph`) | Content script and offscreen | The Web Audio version of the app's track: phase, swap, width, volume, ten-band EQ, convolution reverb, pan, mute, meters. |
| `track-settings.ts`, `messages.ts` | Shared | The settings and message types, and their parsers for untrusted input. |

`chrome-media.d.ts` declares the Chrome-only `captureStream` and `MediaStreamTrackProcessor`.

## How a tab is mixed

1. The app's switch sends `apply` with the tab's settings. The background keeps them, mutes or unmutes the tab through Chrome's own tab mute, and passes them to every frame of the tab.
2. The content script routes playing media elements into its `TrackGraph`, only once the tab is taken over, and only elements whose sound reaches Web Audio. Protected (EME) media and cross-site media without CORS would fall silent, so they are left alone and the tab reports `blocked`. A media element can be routed only once in its life, so the page's audio wiring lives in `globalThis.rookery_page`, shared by every content script that has run in the page; a newer script, as after an extension update, takes it over and retires the old one.
3. For a `blocked` tab, the user clicks the toolbar button: `chrome.tabCapture` (which needs that click) captures the whole tab into the offscreen document, and the page stops processing its own media.
4. Levels are measured only while the app shows a mixer (`meter` command).

## Sidebar videos

`picture_start` makes the frame with the tab's largest playing video call `video.captureStream()` and offer its video track over an `RTCPeerConnection`, H.264 first so both ends use hardware. The offer goes through the background and the browser session to the app, whose `PictureReceiver` (a `WKWebView`) answers; the media then flows over the loopback. `captureStream` keeps delivering frames in a background tab, which a screenshot of the tab could not.

## Lifetime

- When the app goes away, every tab gets its sound back (pages neutral, captures stopped, the tabs the mixer muted unmuted) but its settings are kept; when the app reconnects and sends `hello`, they are applied again. They go when the tab closes or Chrome quits.
- The background retries the connection every 30 seconds through an alarm.
- On install or update, the content script is injected into the tabs already open.

## Identity and installation

- The manifest's `key` fixes the extension id to `lgpadonpeijgfofmlgpgncedeflfifdp`, which the native host's registration allows (`ChromeNativeHost.extensionId`). The private key is not kept; a store release would get a new id, to be set in both places.
- The app writes the host registration into Chrome's per-user `NativeMessagingHosts` directory at launch, pointing at `rookery-chrome-host` inside the installed app.
- Users load `extensions/chrome/dist` unpacked; after a rebuild they press reload in `chrome://extensions`.

## Wire format

`BrowserEvent` and `BrowserCommand` in `RookeryControl/BrowserProtocol.swift`, mirrored by `messages.ts`, with snake_case keys. Decoding is lenient towards older extensions (missing new fields take defaults), and a message the app cannot read is skipped rather than ending the session.
