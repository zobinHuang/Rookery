# rook

<img src="./docs/screenshot.png" />

> A simple tool to keep your coding agents running

## Install

```bash
curl -fsSL -H 'Accept: application/vnd.github.v3.raw' https://api.github.com/repos/zobinHuang/Rookery/contents/rook/setup.sh | bash
```

## Usage

```bash
# create a session and attach to it
rook new <name>

# attach to an existing session
rook attach <name>

# list sessions
rook ls

# kill a session by name
rook kill <name>

# kill the session you're in
rook exit

# upload agent session history to a server
rook connect <host> <port> --token <token>

# stop uploading
rook disconnect
```

See [keybindings](docs/keybindings.md), [session history](docs/sessions.md) and
[playbooks](docs/playbooks.md).
