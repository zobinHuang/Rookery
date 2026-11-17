# roost

The server side of Rookery. It stores the JSON transcripts that Claude Code and
codex write while you work, split by agent and by the account that was logged in,
and it keeps the agents, skills, playbooks and memories they use, holding a live
link to every machine so Rookery can watch them and talk to them. It needs Python
3.10 and the `websockets` package, which setup installs into a virtual
environment of its own.

## Usage

```bash
# deploy, start and health-check in one shot, over HTTPS; prints the client command to run
git clone https://github.com/zobinHuang/Rookery.git ~/Rookery
bash ~/Rookery/server/setup.sh --port 8787 --tls-cert /etc/ssl/roost.crt --tls-key /etc/ssl/roost.key

# open the port and the next one (the live link); without a certificate it serves plain HTTP

# show the token clients need
roost token

# list what has been stored
roost ls
```

Re-running the deploy upgrades in place and keeps the existing token.

See [API.md](API.md) to read sessions back out of a server, and
[session history](../docs/sessions.md) for the storage layout and what ends up on
disk.
