# MuxShots

MuxShots is a macOS window manager that treats every window as its own unit, so windows from many Chrome and VS Code instances can be grouped into virtual workspaces and switched between without native full-screen Spaces. It is for people who keep many windows of the same apps open across several tasks.

## Usage

Requires macOS 14 or later and the Swift 6.2 toolchain.

    scripts/create-dev-certificate.sh   # once: a stable local signing identity
    make run

Grant Accessibility access when prompted, then drag a window toward the top of the screen and drop it on a group. Switch groups with ⌃⌥1–9 or by holding ⌥ and pressing ⇥; ⌃⌥0 shows every window. See [docs/development-plan.md](docs/development-plan.md) for the roadmap.
