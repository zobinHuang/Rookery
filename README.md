# MuxShots

MuxShots is a macOS app that hosts your windows inside a stage of its own: windows you drag into it are grouped, shown one at a time in the stage's content area and switched as tabs and groups, instead of through native full-screen Spaces. Its sidebar also mixes each app's and each Chrome tab's sound, shows Chrome videos picture-in-picture, keeps a world clock, and shows how much of your code agents' plan limits is left. It is for people who keep many windows of the same apps open across several tasks.

## Usage

Requires macOS 14.2 or later and the Swift 6.2 toolchain (the Command Line Tools are enough).

    scripts/create-dev-certificate.sh   # once: a stable local signing identity, so permissions survive rebuilds
    make install                        # build, install to /Applications and open

Grant Accessibility access when asked. Drag a window into the stage to manage it; switch with the tabs, the sidebar, ⌃⌥1–9, or ⌘⇥ while the stage is in front. The sidebar's Mixer asks to record system audio the first time an app is taken over.

To mix Chrome tabs one by one and show their videos in the sidebar, build the extension and load `extensions/chrome/dist` unpacked in `chrome://extensions` with Developer mode on:

    make chrome-extension

`muxctl` drives the running app from a terminal, as `muxctl list`, `muxctl audio` or `muxctl agents`.

See [docs/](docs/) for how it works and how to develop it.
