# rookd

The server side of Rookery. It stores the JSON transcripts that Claude Code and
codex write while you work, split by agent and by the account that was logged in,
and it keeps the agents, skills, playbooks and memories they use, holding a live
link to every machine so Rookery can watch them and talk to them. It needs Python
3.10 and the `websockets` package, which setup installs into a virtual
environment of its own.

## Usage

```bash
# deploy, start and health-check in one shot; prints the client command to run
curl -fsSL -H 'Accept: application/vnd.github.v3.raw' https://api.github.com/repos/zobinHuang/Rookery/contents/server/setup.sh | bash -s -- --port 8787

# serve over HTTPS instead of plain HTTP
server/setup.sh --port 8787 --tls-cert /etc/ssl/rookd.crt --tls-key /etc/ssl/rookd.key

# show the token clients need
rookd token

# list what has been stored
rookd ls
```

Re-running the deploy upgrades in place and keeps the existing token.

See [API.md](API.md) to read sessions back out of a server, and
[session history](../docs/sessions.md) for the storage layout and what ends up on
disk.
