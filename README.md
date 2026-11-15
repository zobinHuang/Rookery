# <img src="docs/images/rookery-logo.png" alt="Rookery" width="258">

Rookery is a macOS app that gathers your windows into a stage of its own: drag a window in and it is grouped with others, shown one at a time and switched as tabs and groups, without full-screen Spaces. A sidebar keeps your tools beside it: quick notes, a world clock, how much of your code agents' plan limits is left, and an optional mixer for each app's and each Chrome tab's sound. It is for people who keep many windows of the same apps open across several tasks.

## Usage

Requires macOS 14.2 or later and the Swift 6.2 toolchain (the Command Line Tools are enough).

    scripts/create-dev-certificate.sh   # once: a stable signing identity, so permissions survive rebuilds
    make install                        # build, install to /Applications and open

Grant Accessibility access when asked, then drag a window into the stage. Switch with the tabs and the sidebar, ⌃⌥1–9, or ⌘⇥ while the stage is in front; the settings are behind the gear at the bottom of the sidebar.

The mixer is off until you turn it on under General in the settings. To mix Chrome tabs one by one and show their videos in the sidebar, build the extension and load `extensions/chrome/dist` unpacked in `chrome://extensions` with Developer mode on:

    make chrome-extension

`swift build` also builds `rookeryctl`, which drives the running app from a terminal, as in `.build/debug/rookeryctl list`.

See [docs/](docs/) for how it works and how to develop it, and [branding/](branding/) for the pixel crow logo.
