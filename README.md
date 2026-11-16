# <img src="docs/images/rookery-logo.png" alt="Rookery" width="258">

Rookery watches over your code agents. `rook` runs them in tmux on each of your machines and reports what each is doing; `roost`, a server, gathers their sessions, skills, playbooks and memories; and Rookery, a macOS app, shows every agent as a crow you can read, prompt and organize, beside a stage for your windows.

## Deploy

**roost**, on a server the other machines can reach (Python 3.10+). It listens on a port and the next one, for its API and its live link; open both. A certificate is optional but recommended.

    git clone git@github.com:zobinHuang/Rookery.git ~/Rookery
    bash ~/Rookery/server/setup.sh --port 8787 --tls-cert <cert> --tls-key <key>
    ~/.local/bin/roost token        # the token every client needs

**rook**, on each machine where your agents run (tmux, Python 3.10+):

    git clone git@github.com:zobinHuang/Rookery.git ~/Rookery
    bash ~/Rookery/rook/setup.sh
    rook connect <roost host> 8787 --token <token> --tls

**Rookery**, on your Mac (macOS 14.2+, the Swift 6.2 toolchain):

    scripts/create-dev-certificate.sh   # once, so permissions survive rebuilds
    make install

Then in Rookery's settings, under Roost, enter `https://<roost host>:8787` and the token, and connect. To upgrade any of them, `git pull` and run the same command again.

## Use

    rook new <name>                   # a tmux session; start Claude Code or codex in its panes
    rook message <agent> "..."        # tell another agent something, from an agent's pane
    rook resource ls --kind agent     # what roost knows

In Rookery, the sidebar's Agents mode lists every agent as a crow playing its state; click one to read its conversation and prompt it, and drag agents into groups. Rookmaster, at the top of that list, shows every resource and what used what, the live log, and an agent on your Mac that tidies roost's skills, playbooks and memories when you ask.

More in [rook/](rook/README.md), [server/](server/README.md) and [docs/](docs/).
