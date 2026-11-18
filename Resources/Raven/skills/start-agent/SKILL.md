---
name: start-agent
description: Propose starting a new code agent on one of the user's hosts, in a workdir or project directory, with the playbook and skills it should have, who it is, the teams it joins, and a first prompt. Use when the user asks to start, spin up, launch or open an agent somewhere, or to add an agent to a team's work.
---

# Start an agent

1. Find the place: `rook-client host list`. Each host shows its rook, whether it is online, and the workdirs the user set up there with what an agent started in each begins with. Prefer a workdir that fits the request, and start from its playbook, skills, role and teams. If the user named no host, pick the one their agents on that project run on (`rook-client agent status --all --json`: `rook` and `project`), and say so. The rook must be online.
2. Find the directory: the workdir's path, or an absolute path the user gave, or the `cwd` of an earlier agent on the same project (`rook-client resource get agent <id>`). A workdir marked a parent is not a directory to start in: give the agent a new one inside it, `<path>/<MMDD-name>`, today's month and day and a short name for the work in lowercase with dashes (as `/mnt/projects/1119-glm53flash`). The rook creates a directory that does not exist yet as the agent starts. Never guess a path that no workdir or agent has used. When the user wants a workdir kept on a host, propose it: `rook-client propose workdir <host> <path> [--parent] [--name "..."]`.
3. Decide what it begins with:
   - `--playbook <id>` and `--skill <id>` (repeatable) for what to install first; check them with `rook-client resource ls --kind playbook` and `--kind skill`.
   - `--role "..."`, always: who it is to its teammates, a noun phrase under 12 words, as "owner of the G-Watch ISA decoder", in the language the user wrote to you in. Take the workdir's role when it fits the request; otherwise write it from what the user asked for. Rookery keeps it up to date from the agent's work afterwards.
   - `--team <team id>:<duty>` (repeatable) for each team it joins, with its duty there; `rook-client team list` shows the teams.
4. Write the first prompt as the user would type it to start the work: the task, the constraints they gave, and where to report. Empty is fine when the user wants the agent open and will prompt it later.
5. Propose it: `rook-client propose spawn <rook> --cwd <dir> --role "..." [--harness codex] [--playbook ...] [--skill ...] [--team ...] "<first prompt>"`. `<rook>` is the rook's name as `host list` shows it; a machine's own host name, as a roster's `(host ...)`, finds its rook too. One proposal per session: a second for the same rook and directory replaces the first.
6. Tell the user in a line what you proposed and where; the Start button shows under your answer. Once started, the session reports itself, joins its teams, is told of its teammates, and shows up in `rook-client agent status` within a few seconds.
