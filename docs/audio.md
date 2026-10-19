# Audio mixer

How MuxShots takes over an app's sound and plays it back treated.

## Capturing an app

- **Processes**: `AudioProcessDirectory` lists Core Audio's process objects with their pids and bundle ids. An app's sound often comes from helpers (a browser's audio service), so a process belongs to an app when its bundle id is the app's or starts with it followed by a dot. Safari's sound comes from `com.apple.WebKit.GPU` and is not matched yet.
- **Tap** (`ProcessTap`): a Core Audio process tap (`CATapDescription(stereoMixdownOfProcesses:)`, private, `mutedWhenTapped`) over the app's playing processes, read through a private aggregate device whose main subdevice is the default output. Tapping silences the app elsewhere; destroying the tap gives the sound back.
- The tap is renewed as processes come and go; processes already tapped are kept while they live, so a pause does not tear the tap down.
- A muted app is captured even when not taken over, and silenced at its track's output.

## Playing it back

Each taken-over app gets a track in one `AVAudioEngine`: an `AVAudioSourceNode` reading a ring buffer the tap's IO proc fills → `StereoProcessor` (per-channel phase inversion, channel swap, mid/side width, gain, peak meters) → `AVAudioUnitEQ` (ten bands, shelves at the ends) → `AVAudioUnitReverb` → a per-track mixer node for pan and mute → the main mixer. The ring buffer holds at most 40 ms, which bounds the added delay. A change of output device rebuilds every track.

## Settings and meters

- `MixerTrackSettings` (Core) is the one settings type for apps and tabs alike; decoding fills in defaults for keys added later, so stored settings survive new fields. Settings are clamped on the way in.
- Per-app settings are stored by bundle id and applied again at launch.
- Meters are read only while a mixer is on screen (`MixerController.beginShowingMeters`), and only the meter views redraw on a new level.

## Gotchas

- Swift 6 gives a closure the isolation of the context it is written in. A render or IO block created inside a `@MainActor` method traps on the audio thread; build such blocks in `nonisolated static` functions.
- The first takeover asks for system audio recording; without `NSAudioCaptureUsageDescription` in `Info.plist` the tap fails.
