# Code agent usage

The sidebar's propellant panel shows how much of each code agent account's plan limits is left and when each resets.

## Reading the limits

Each harness has an `AgentUsageProvider` (`RookeryPlatform`), which reads an account's limits by asking the harness itself, so MuxShots never handles the account's credentials. Adding a harness means a case in `AgentHarness`, its markers in `AgentDirectoryContents`, its sign-in command, and a provider declaring its `minimumInterval`.

**Claude Code** (`ClaudeCodeUsageProvider`) runs

    claude -p --input-format stream-json --output-format stream-json --verbose \
        --no-session-persistence --setting-sources ""

with `CLAUDE_CONFIG_DIR` set for accounts other than the default, writes two control requests, `initialize` and `get_usage` with `skip_behaviors`, and closes its input. Claude Code answers and exits, in about a second. No prompt is sent, so no model is called; `--no-session-persistence` leaves no transcript; `--setting-sources ""` keeps the user's hooks from running. (`--bare` would not do: it never reads the OAuth sign-in.)

- `initialize` answers with `account.email`, `account.organization` and `account.subscriptionType`, the plan's full name ("Claude Max", "Claude Ultra"). The panel takes the plan from it, since `get_usage` says "max" for an Ultra plan too.
- `get_usage` answers with `subscription_type`, `rate_limits_available` and `rate_limits.limits`: one entry per limit with `kind` (`session`, `weekly_all`, `weekly_scoped`), `group`, `percent` used (0–100), `resets_at`, `severity` and, for model-scoped ones, `scope.model.display_name`. `ClaudeCodeUsageDecoder` reads it.

The provider reads output with a readability handler and kills the process on timeout or cancellation: a blocking read of a pipe cannot be cancelled, and Claude Code shuts down gracefully on SIGTERM, which left reads hanging.

## Schedule

- Claude Code caches its own usage, merges concurrent fetches and handles `rate_limit_error`: its usage endpoint is rate limited. Reads are therefore at most every 5 minutes (the provider's `minimumInterval`), doubling after failures up to 30 minutes; the refresh button is ignored within a minute of the last read.
- A reset needs no read: once its time passes, the panel shows the limit full until the next read brings the new window.

## Accounts

- An account is a harness and its configuration directory; the default directory is `nil`. `Preferences.listAgentAccounts` holds them, set up with the default Claude Code account when `~/.claude` exists. Adding one in the settings inspects the chosen directory to tell its harness; an empty directory is taken for a new Claude Code account, whose sign-in command (`CLAUDE_CONFIG_DIR=… claude auth login`) the settings offer to copy.
- Accounts signed in to the same login (harness and email) are read once and shown once, marked "default" when the default account is among them; `AgentUsageMonitor.listAccountGroups` does the grouping.

## Display

`AgentUsagePanel`: a gauge per limit drained from the right as it is used, the share left, and the reset countdown on a segment display. A limit running out (a tenth left, or the harness says critical) gets a light red row; a used-up one fades all but its countdown.
