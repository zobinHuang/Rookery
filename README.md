# MuxShots

MuxShots is a macOS app that fills a display with a stage and hosts your windows inside it: windows you hand to it are grouped, shown one at a time in the stage's content area, and switched as tabs and groups instead of through native full-screen Spaces. It is for people who keep many windows of the same apps open across several tasks.

## Usage

Requires macOS 14.2 or later and the Swift 6.2 toolchain.

    scripts/create-dev-certificate.sh   # once: a stable local signing identity
    make install                        # builds, installs to /Applications and opens it

Grant Accessibility access when prompted. MuxShots then opens its stage; open it again from the Dock, Launchpad or Spotlight, or press ⌃⌥↩. Drag a window into the stage to manage it, and switch with the tabs, the sidebar, ⌃⌥1–9 or by holding ⌥ and pressing ⇥.

The sidebar's Mixer takes over the sound of the apps you switch on there, after you allow MuxShots to record system audio, and adjusts each one's volume, pan, stereo width, channel phase, ten-band equalizer and reverb. The settings are remembered per app; switching an app off gives its sound back untouched. The same controls are on the command line: `muxctl audio`, `muxctl audio take <bundle-id>`, `muxctl audio set <bundle-id> volume=0.8 eq3=4 mix=20`.

See [docs/development-plan.md](docs/development-plan.md) for the roadmap.
