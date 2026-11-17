#!/usr/bin/env bash
set -euo pipefail

# --name <name> names this machine's agents (`<name>/<tab>`); otherwise the
# installer asks, defaulting to the name set before or the short host name.
# --no-service installs rook-link without starting it as a user service.
ROOK_NAME="${ROOK_NAME:-}"
ROOK_DO_SERVICE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --name) ROOK_NAME="${2:-}"; shift 2 ;;
    --no-service) ROOK_DO_SERVICE=0; shift ;;
    *) echo "rook setup: unknown option $1" >&2; exit 1 ;;
  esac
done

# ─── colors ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

# ─── fetch a file from this repo's raw API (avoids CDN cache) ────────
ROOK_REPO_API="https://api.github.com/repos/zobinHuang/Rookery/contents/rook"
rook_fetch() {
  # rook_fetch <repo-path> <local-dest>
  # On failure, captures curl's stderr + http status into the global
  # ROOK_FETCH_ERR so the caller can surface it to the user.
  local src="$1" dest="$2" curl_err http_code curl_rc
  ROOK_FETCH_ERR=""
  curl_err="$(mktemp)"
  http_code="$(curl -sSL -w '%{http_code}' \
                -H 'Accept: application/vnd.github.v3.raw' \
                "${ROOK_REPO_API}/${src}" \
                -o "$dest" 2>"$curl_err")"
  curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then
    ROOK_FETCH_ERR="curl exit=$curl_rc: $(tr '\n' ' ' <"$curl_err")"
    rm -f "$curl_err"
    return 1
  fi
  rm -f "$curl_err"
  case "$http_code" in
    2??) return 0 ;;
    *)
      # On non-2xx the body was written to $dest — peek at it for the
      # actual GitHub error (rate-limit, 404, etc). Truncate so we don't
      # spam the terminal with a full HTML page.
      ROOK_FETCH_ERR="HTTP $http_code from ${ROOK_REPO_API}/${src} — $(head -c 200 "$dest" 2>/dev/null | tr '\n' ' ')"
      rm -f "$dest"
      return 1
      ;;
  esac
}

# When running `bash setup.sh` from a clone, prefer the local file. When
# running via `curl|bash`, BASH_SOURCE points to /dev/fd/N or main and the
# sibling check fails, so we fall back to fetching from GitHub.
ROOK_SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  ROOK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
fi
ROOK_INSTALL_ERR=""

rook_install_file() {
  # rook_install_file <repo-path> <dest>
  # On failure, sets ROOK_INSTALL_ERR with a human-readable reason.
  local src="$1" dest="$2"
  ROOK_INSTALL_ERR=""
  if [ -n "$ROOK_SCRIPT_DIR" ] && [ -f "$ROOK_SCRIPT_DIR/$src" ]; then
    if ! cp "$ROOK_SCRIPT_DIR/$src" "$dest" 2>/dev/null; then
      ROOK_INSTALL_ERR="cp $ROOK_SCRIPT_DIR/$src -> $dest failed"
      return 1
    fi
    return 0
  fi
  if rook_fetch "$src" "$dest"; then
    return 0
  fi
  ROOK_INSTALL_ERR="$ROOK_FETCH_ERR"
  return 1
}

# ──────────────────────────────────────────────────────────────────────
COMMIT_HASH="$(curl -fsSL https://api.github.com/repos/zobinHuang/Rookery/commits/main 2>/dev/null | grep -m1 '"sha"' | cut -d'"' -f4 | cut -c1-7)" || true
COMMIT_HASH="${COMMIT_HASH:-unknown}"

echo ""
echo "══════════════════════════════════════════════════"
echo "  rook setup"
echo "  commit: $COMMIT_HASH"
echo "══════════════════════════════════════════════════"

# ─── 1. tmux ─────────────────────────────────────────────────────────
echo ""
echo "── tmux ─────────────────────────────────────────"

if command -v tmux &>/dev/null; then
  info "tmux already installed ($(tmux -V))"
else
  err "tmux not found. Please install tmux first (e.g. sudo apt install tmux)"
fi

# ─── patch tmux config ────────────────────────────────────────────────
TMUX_CONF="$HOME/.tmux.conf"

# rook owns one block of each dotfile it configures, between these markers,
# and rewrites only that block: whatever else is in the file is the user's and
# stays as it was. The block goes at the end, so where a line of the user's and
# one of rook's set the same option, rook's wins, as it did when rook wrote
# the whole file.
rook_write_block() {
  # rook_write_block <file> <comment-leader> — the block's lines come on stdin
  local file="$1" leader="$2" begin end kept
  begin="$leader >>> rook >>>"
  end="$leader <<< rook <<<"
  kept="$(mktemp)"
  if [ -f "$file" ]; then
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { inside = 1; next }
      $0 == end   { inside = 0; next }
      !inside
    ' "$file" > "$kept"
  fi
  {
    cat "$kept"
    [ -s "$kept" ] && [ -n "$(tail -c 1 "$kept")" ] && echo ""
    echo "$begin"
    cat
    echo "$end"
  } > "$file.rook-tmp"
  rm -f "$kept"
  mv "$file.rook-tmp" "$file"
}

rook_write_block "$TMUX_CONF" "#" <<'TMUX'

# ─── clipboard & input ───────────────────────────────────────────────
set -g default-terminal "xterm-256color"
set -g set-clipboard on
if-shell "tmux -V | awk '{if($2+0 >= 3.3) exit 0; else exit 1}'" "set -g allow-passthrough on" ""
set -g mouse on
set -g mode-keys vi

# ─── mouse/vi copy → pipe through osc52-copy for clipboard ──────────
bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "~/.local/bin/osc52-copy"
bind -T copy-mode MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "~/.local/bin/osc52-copy"
bind -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "~/.local/bin/osc52-copy"

# ─── smart navigation: Alt + arrows (pane first, then the bar) ──────
# Left/right walk panes until you hit an edge, then keep going along the
# status bar. Once agents are running the bar has two rows, and they are
# walked as one sequence — the whole READY row, then the whole BUSY row —
# so stepping right off the end of the top row continues onto the bottom
# one. That is the order you read the bar in.
#
# Up/down stay pane-only. Vertical row-crossing was tried and dropped:
# with one tab per row every up/down press is a legitimate no-op, which
# is indistinguishable from a broken keybinding, and Alt+Up/Down is eaten
# outright by some terminals (VS Code binds it to move-line).
#
# With no agent running every tab sits in the ready row, so left/right
# behave exactly like previous-window/next-window did before the bar.
#
# -b is required, not an optimisation: run-shell without it blocks the
# server until the command returns, and rook-agent calls back into tmux.
bind -n M-Left  if-shell -F "#{pane_at_left}"   'run-shell -b "$HOME/.local/bin/rook-agent nav left #{window_id}"'  "select-pane -L"
bind -n M-Right if-shell -F "#{pane_at_right}"  'run-shell -b "$HOME/.local/bin/rook-agent nav right #{window_id}"' "select-pane -R"
bind -n M-Up    if-shell -F "#{pane_at_top}"    "" "select-pane -U"
bind -n M-Down  if-shell -F "#{pane_at_bottom}" "" "select-pane -D"

# ─── tab mode: Ctrl+t → action ───────────────────────────────────────
bind -n C-t switch-client -T tab_mode
bind -T tab_mode n new-window -c "#{pane_current_path}"
bind -T tab_mode r command-prompt -I "#W" "rename-window '%%'"
bind -T tab_mode x kill-window
# Clear a tab stuck showing an agent state — an agent SIGKILLed with its
# pane left open never runs SessionEnd, and no tmux hook fires either.
bind -T tab_mode c run-shell -b "$HOME/.local/bin/rook-agent clear #{window_id}"
# Swap this pane's playbook while an agent is running in it. The agent is
# told on its next turn, by the UserPromptSubmit hook. display-popup needs
# tmux 3.2, and a client attached to draw on — which is the case whenever
# you are there to press the key.
# run-shell, not display-popup directly: display-popup passes #{...} to
# the shell unexpanded, so the picker would be handed the literal text
# instead of this pane and its directory. run-shell does expand them, and
# -b keeps the server from blocking while the popup is up.
if-shell "tmux -V | awk '{if($2+0 >= 3.2) exit 0; else exit 1}'" \
  "bind -T tab_mode p run-shell -b \"$HOME/.local/bin/rook-playbook pick-here '#{pane_id}' '#{pane_current_path}'\"" \
  "bind -T tab_mode p display-message 'playbooks need tmux 3.2 or newer'"
bind -T tab_mode Left previous-window
bind -T tab_mode Right next-window
bind -T tab_mode h previous-window
bind -T tab_mode l next-window
bind -T tab_mode 1 select-window -t 1
bind -T tab_mode 2 select-window -t 2
bind -T tab_mode 3 select-window -t 3
bind -T tab_mode 4 select-window -t 4
bind -T tab_mode 5 select-window -t 5
bind -T tab_mode 6 select-window -t 6
bind -T tab_mode 7 select-window -t 7
bind -T tab_mode 8 select-window -t 8
bind -T tab_mode 9 select-window -t 9
# Nested-tmux passthrough: Ctrl+t Ctrl+t forwards Ctrl+t to the pane.
# Use case: `rook` running locally with an inner `rook` over SSH.
bind -T tab_mode C-t send-keys C-t
# Alt+arrows aren't chord triggers, so the outer always intercepts them.
# `Ctrl+t Alt+<dir>` forwards the chord to the pane for quick inner-side
# pane/window navigation. For longer stretches of inner-side work, use
# F12 to fully disable outer bindings (see below).
bind -T tab_mode M-Left  send-keys M-Left
bind -T tab_mode M-Right send-keys M-Right
bind -T tab_mode M-Up    send-keys M-Up
bind -T tab_mode M-Down  send-keys M-Down

# ─── pane mode: Ctrl+p → action ─────────────────────────────────────
bind -n C-p switch-client -T pane_mode
bind -T pane_mode d split-window -v -c "#{pane_current_path}"
bind -T pane_mode n split-window -h -c "#{pane_current_path}"
bind -T pane_mode x kill-pane
bind -T pane_mode Left select-pane -L
bind -T pane_mode Right select-pane -R
bind -T pane_mode Up select-pane -U
bind -T pane_mode Down select-pane -D
bind -T pane_mode h select-pane -L
bind -T pane_mode j select-pane -D
bind -T pane_mode k select-pane -U
bind -T pane_mode l select-pane -R
bind -T pane_mode z resize-pane -Z
# Nested passthrough — Ctrl+p Ctrl+p forwards Ctrl+p
bind -T pane_mode C-p send-keys C-p

# ─── resize mode: Ctrl+n → h/j/k/l (repeatable) ────────────────────
bind -n C-n switch-client -T resize_mode
bind -r -T resize_mode h resize-pane -L 2
bind -r -T resize_mode j resize-pane -D 2
bind -r -T resize_mode k resize-pane -U 2
bind -r -T resize_mode l resize-pane -R 2
bind -r -T resize_mode Left resize-pane -L 2
bind -r -T resize_mode Right resize-pane -R 2
bind -r -T resize_mode Up resize-pane -U 2
bind -r -T resize_mode Down resize-pane -D 2
# Nested passthrough — Ctrl+n Ctrl+n forwards Ctrl+n
bind -T resize_mode C-n send-keys C-n

# ─── F12: nested-tmux passthrough toggle ─────────────────────────────
# When you're inside an inner tmux (e.g. SSH'd into a remote rook),
# the outer tmux intercepts Ctrl+t/p/n and Alt+arrows. F12 swaps the
# active key-table to "off" so every outer binding becomes inert and
# keystrokes pass straight through to the pane (= the inner tmux).
# Press F12 again to restore the outer's bindings. status-left shows
# `[PASSTHRU]` while in off-mode so you don't forget you're in it.
bind -T root F12 set key-table off \; refresh-client -S
bind -T off  F12 set -u key-table  \; refresh-client -S

# ─── keep custom tab names ───────────────────────────────────────────
setw -g automatic-rename off
set -g allow-rename off

# ─── windows start at 1 (not 0) ─────────────────────────────────────
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# ─── status bar (tab bar) ────────────────────────────────────────────
set -g status-position bottom
set -g status-style "bg=#1e1e2e,fg=#cdd6f4"
set -g status-left-length 80
# One attribute per #[...] here, as in the agent rows below: a comma
# inside #[bg=x,fg=y] sits inside a #{?...}, and escaping it as "#," is
# only understood by newer tmux. Older builds split the conditional at
# that comma instead and print the rest of the style as literal text
# (seen on CentOS as `fg=#1e1e2e#,bold] PASSTHRU ,` in the bar).
#
# `#h` is tmux's short hostname (no domain). A bright yellow [PASSTHRU]
# block appears when F12 has switched the active key-table to "off"
# (nested-tmux passthrough mode).
set -g status-left "#[bg=#cba6f7,fg=#1e1e2e,bold] rook [#h] #[default] #[bg=#89b4fa,fg=#1e1e2e,bold] ◆ #S #[default]#{?#{==:#{client_key_table},off}, #[bg=#f9e2af]#[fg=#1e1e2e]#[bold] PASSTHRU #[default],} "
set -g status-right-length 80
# Per-tab uptime (#(rook-uptime)) + clock. rook-uptime prints the elapsed
# time since the current window (tab) was created, falling back to session
# creation for windows that pre-date the install.
set -g status-right "#[fg=#a6e3a1]running #($HOME/.local/bin/rook-uptime)#[default] #[fg=#a6adc8]│ %Y-%m-%d %H:%M "
set -g status-interval 1
# #{=14:...} is the plain trim, understood far back; the #{=/14/…:...}
# form that appends an ellipsis is newer and renders empty on old tmux.
setw -g window-status-format "#[fg=#a6adc8] #I:#{=14:window_name} "
setw -g window-status-current-format "#[bg=#45475a,fg=#89b4fa,bold] ▸ #I:#{=14:window_name} "
setw -g window-status-separator ""

# ─── agent bar: READY / BUSY rows ────────────────────────────────────
# Each window carries a @rook-agent option (busy | wait | idle | unset)
# written by `rook-agent`, which code-agent hooks call. The rows below
# filter the window list on it, entirely in tmux's format language — no
# #(), so the 1s redraw stays free of subprocesses (see commit 1f15349
# for what a second #() did to refresh behaviour).
#
# Two conventions keep these strings readable:
#   * one attribute per #[...] — a comma inside #[bg=x,fg=y] would be
#     read as a #{?...} argument separator and split the conditional.
#   * the row templates live here as user options; rook-agent only ever
#     writes `status-format[N] = #{E:@rook-row-<name>}` into a session,
#     so it never has to re-quote any of this.

# READY row items — anything not busy: waiting on you, idle, or a plain
# tab that has never run an agent (dim, no glyph).
set -g @rook-ready-item "#{?#{==:#{@rook-agent},busy},,#[range=window|#{window_index}]#{?#{==:#{@rook-agent},wait},#[fg=#f9e2af] ! #I:#{=14:window_name} ,#{?#{==:#{@rook-agent},idle},#[fg=#a6e3a1] ○ #I:#{=14:window_name} ,#[fg=#6c7086]   #I:#{=14:window_name} }}#[default]#[norange]}"
set -g @rook-ready-cur  "#{?#{==:#{@rook-agent},busy},,#[range=window|#{window_index}]#[list=focus]#[bg=#45475a]#[fg=#89b4fa]#[bold] ▸ #I:#{=14:window_name} #[default]#[norange]#[list=on]}"

# BUSY row items — agent currently working.
set -g @rook-busy-item "#{?#{==:#{@rook-agent},busy},#[range=window|#{window_index}]#[fg=#fab387] ● #I:#{=14:window_name} #[default]#[norange],}"
set -g @rook-busy-cur  "#{?#{==:#{@rook-agent},busy},#[range=window|#{window_index}]#[list=focus]#[bg=#45475a]#[fg=#fab387]#[bold] ▸ ● #I:#{=14:window_name} #[default]#[norange]#[list=on],}"

# Row templates. #{W:normal,current} loops the window list and picks the
# second format for the current window, so neither item format has to
# test for it.
set -g @rook-row-ready "#[align=left]#[bg=#a6e3a1]#[fg=#1e1e2e]#[bold] READY #[default] #[list=on]#[list=left-marker]<#[list=right-marker]>#[list=on]#{W:#{E:@rook-ready-item},#{E:@rook-ready-cur}}#[nolist]"
set -g @rook-row-busy  "#[align=left]#[bg=#fab387]#[fg=#1e1e2e]#[bold] BUSY  #[default] #[list=on]#[list=left-marker]<#[list=right-marker]>#[list=on]#{W:#{E:@rook-busy-item},#{E:@rook-busy-cur}}#[nolist]"
# Chrome row — the default status line minus the window list, which the
# agent rows have taken over. Always the bottom row, so the clock stays
# put as rows appear and disappear above it.
set -g @rook-row-chrome "#[align=left range=left #{E:status-left-style}]#[push-default]#{T;=/#{status-left-length}:status-left}#[pop-default]#[norange default]#[align=right range=right #{E:status-right-style}]#[push-default]#{T;=/#{status-right-length}:status-right}#[pop-default]#[norange default]"

# ─── pane borders ────────────────────────────────────────────────────
set -g pane-border-style "fg=#45475a"
set -g pane-active-border-style "fg=#89b4fa"

# ─── per-tab uptime: stamp window creation time so rook-uptime can show
#     "running 5m 30s" relative to when this tab opened, not when the
#     session opened. Uses run-shell + date because #{T:%s} is empty on
#     recent tmux builds (the strftime %s format isn't reliably compiled in).
#     The same hook then resyncs the agent bar (below): one hook holding
#     both commands, as tmux before 3.0 cannot append to a hook.
set-hook -g after-new-window  'run-shell -b "tmux set-option -w -t #{window_id} @rook-window-created \"$(date +%s)\"" ; run-shell -b "$HOME/.local/bin/rook-agent sync"'
set-hook -g after-new-session 'run-shell -b "tmux set-option -w -t #{window_id} @rook-window-created \"$(date +%s)\"" ; run-shell -b "$HOME/.local/bin/rook-agent sync"'

# ─── agent bar: keep the row count in step with windows and panes ────
# -g, not -ga, for these: nothing else writes them, and sourcing this
# file again (which is exactly what a hot upgrade does) would otherwise
# append a duplicate every time, so each event would fire sync N times.
# The two above must stay -ga because the uptime stamps own index 0.
set-hook -g  session-created   'run-shell -b "$HOME/.local/bin/rook-agent sync"'
set-hook -g  client-attached   'run-shell -b "$HOME/.local/bin/rook-agent sync"'
set-hook -g  window-unlinked   'run-shell -b "$HOME/.local/bin/rook-agent sync"'
# A pane going away takes its agent with it; without these, a tab whose
# agent was killed mid-run would sit in BUSY forever. Both are needed and
# they don't overlap: a pane whose command exits fires pane-exited, while
# `Ctrl+p x` runs kill-pane, which fires only after-kill-pane.
set-hook -g  pane-exited       'run-shell -b "$HOME/.local/bin/rook-agent sync"'
set-hook -g  after-kill-pane   'run-shell -b "$HOME/.local/bin/rook-agent sync"'
set-hook -g  pane-died         'run-shell -b "$HOME/.local/bin/rook-agent sync"'
TMUX
info "Updated rook's block of .tmux.conf (tabs, panes, Alt keybindings, status bar)"

# ─── install OSC 52 clipboard helper ─────────────────────────────────
mkdir -p "$HOME/.local/bin"
OSC52_BIN="$HOME/.local/bin/osc52-copy"
printf '%s' '#!/usr/bin/env bash
data=$(base64 | tr -d '"'"'\n'"'"')
PANE_TTY=$(tmux display-message -p "#{pane_tty}" 2>/dev/null || true)
if [ -n "$PANE_TTY" ] && [ -e "$PANE_TTY" ]; then
  printf '"'"'\033]52;c;%s\a'"'"' "$data" > "$PANE_TTY"
else
  printf '"'"'\033]52;c;%s\a'"'"' "$data" > /dev/tty
fi
' > "$OSC52_BIN"
chmod +x "$OSC52_BIN"
info "Installed osc52-copy helper"

# ─── patch vimrc ──────────────────────────────────────────────────────
VIMRC="$HOME/.vimrc"

rook_write_block "$VIMRC" '"' <<'VIM'
syntax on
set number
VIM
info "Updated rook's block of .vimrc (line numbers + syntax highlighting)"

# ─── 3. helper scripts ───────────────────────────────────────────────
echo ""
echo "── helpers ───────────────────────────────────────"

mkdir -p "$HOME/.local/bin"

# Always overwrite so re-running setup.sh upgrades these
_rook_install_or_fail() {
  # _rook_install_or_fail <repo-path> <dest> <label>
  if rook_install_file "$1" "$2"; then
    return 0
  fi
  err "Failed to install $3 — ${ROOK_INSTALL_ERR:-<no error captured>}"
  return 1
}

if _rook_install_or_fail bin/rook-uptime "$HOME/.local/bin/rook-uptime" "rook-uptime"; then
  chmod +x "$HOME/.local/bin/rook-uptime"
  info "Installed rook-uptime"
fi

if _rook_install_or_fail bin/rook-agent "$HOME/.local/bin/rook-agent" "rook-agent"; then
  chmod +x "$HOME/.local/bin/rook-agent"
  info "Installed rook-agent"
fi

if _rook_install_or_fail bin/rook-hooks "$HOME/.local/bin/rook-hooks" "rook-hooks"; then
  chmod +x "$HOME/.local/bin/rook-hooks"
  info "Installed rook-hooks"
fi

if _rook_install_or_fail bin/rook-session "$HOME/.local/bin/rook-session" "rook-session"; then
  chmod +x "$HOME/.local/bin/rook-session"
  info "Installed rook-session"
fi

if _rook_install_or_fail bin/rook-client "$HOME/.local/bin/rook-client" "rook-client"; then
  chmod +x "$HOME/.local/bin/rook-client"
  info "Installed rook-client"
fi

if _rook_install_or_fail bin/rook-link "$HOME/.local/bin/rook-link" "rook-link"; then
  chmod +x "$HOME/.local/bin/rook-link"
  info "Installed rook-link"
fi

if _rook_install_or_fail bin/rook-playbook "$HOME/.local/bin/rook-playbook" "rook-playbook"; then
  chmod +x "$HOME/.local/bin/rook-playbook"
  info "Installed rook-playbook"
fi

# The skill that tells Claude Code how to work with its teammates, which rook names to it as a session starts.
ROOK_TEAM_SKILL_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/rook-team"
if mkdir -p "$ROOK_TEAM_SKILL_DIR" \
  && _rook_install_or_fail skills/rook-team/SKILL.md "$ROOK_TEAM_SKILL_DIR/SKILL.md" "the rook-team skill"; then
  info "Installed the rook-team skill into $ROOK_TEAM_SKILL_DIR"
fi

# ─── 4. install rook command ─────────────────────────────────────
echo ""
echo "── rook command ──────────────────────────────"

ROOK_BIN="$HOME/.local/bin/rook"

if _rook_install_or_fail bin/rook "$ROOK_BIN" "rook"; then
  chmod +x "$ROOK_BIN"
  info "Installed rook command to $ROOK_BIN"
fi

# ensure ~/.local/bin is in PATH
SHELL_RC="$HOME/.bashrc"
[ -n "${ZSH_VERSION:-}" ] && SHELL_RC="$HOME/.zshrc"
PATH_MARKER="# [rook] path"

# remove old rook path line if exists, then write fresh.
# Brackets in PATH_MARKER are regex metacharacters; literal-match them.
sed -i.bak '/# \[rook\] path/,+1d' "$SHELL_RC" 2>/dev/null || true
rm -f "${SHELL_RC}.bak"

PATH_LINE="export PATH=\"\$HOME/.local/bin:\$PATH\""
printf '\n%s\n%s\n' "$PATH_MARKER" "$PATH_LINE" >> "$SHELL_RC"
info "Added rook PATH to $(basename "$SHELL_RC")"
warn "Run 'source $SHELL_RC' or restart your shell"

# Strip any vibe-music shell-hook line left by older installs (idempotent).
for RC in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$RC" ] || continue
  # Brackets in the marker are regex metacharacters; literal-match them.
  sed -i.bak '/# \[rook\] vibe-hooks/,+1d' "$RC" 2>/dev/null || true
  rm -f "${RC}.bak"
done

# ─── rook name ───────────────────────────────────────────────────────
echo ""
echo "── rook name ─────────────────────────────────────"

ROOK_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/rook/config.json"
ROOK_NAME_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
ROOK_NAME_DEFAULT=""
if [ -f "$ROOK_CONFIG_FILE" ]; then
  ROOK_NAME_DEFAULT="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOK_CONFIG_FILE" | head -1)"
fi
[ -n "$ROOK_NAME_DEFAULT" ] || ROOK_NAME_DEFAULT="$(hostname 2>/dev/null | cut -d. -f1)"
# Read from the terminal, not stdin: under `curl | bash` stdin is this script.
if [ -z "$ROOK_NAME" ] && ( : < /dev/tty ) 2>/dev/null; then
  printf '  Name this machine'"'"'s agents go by [%s]: ' "$ROOK_NAME_DEFAULT" > /dev/tty
  read -r ROOK_NAME < /dev/tty || ROOK_NAME=""
fi
ROOK_NAME="${ROOK_NAME:-$ROOK_NAME_DEFAULT}"
if ! printf '%s' "$ROOK_NAME" | grep -Eq "$ROOK_NAME_PATTERN"; then
  warn "\"$ROOK_NAME\" is not a usable name (letters, digits, . _ -); using $ROOK_NAME_DEFAULT"
  ROOK_NAME="$ROOK_NAME_DEFAULT"
fi
mkdir -p "$(dirname "$ROOK_CONFIG_FILE")"
python3 - "$ROOK_CONFIG_FILE" "$ROOK_NAME" <<'PY'
import json, sys
path, name = sys.argv[1], sys.argv[2]
try:
    with open(path) as handle:
        config = json.load(handle)
except (OSError, ValueError):
    config = {}
if not isinstance(config, dict):
    config = {}
config["name"] = name
with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
    handle.write("\n")
PY
info "Agents here go by $ROOK_NAME/<tab>"

# ─── 5. code-agent hooks ─────────────────────────────────────────────
echo ""
echo "── code-agent hooks ──────────────────────────────"

ROOK_CODEX_NEEDS_TRUST=0
while IFS=: read -r ROOK_HOOK_AGENT ROOK_HOOK_RESULT; do
  ROOK_HOOK_RESULT="${ROOK_HOOK_RESULT# }"
  case "$ROOK_HOOK_AGENT:$ROOK_HOOK_RESULT" in
    claude:merged) info "Merged Claude Code hooks into ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" ;;
    codex:merged)  info "Merged Codex hooks into ${CODEX_HOME:-$HOME/.codex}/hooks.json"
                   ROOK_CODEX_NEEDS_TRUST=1 ;;
    codex:absent)  ;;
    *:no-json-tool)
      warn "Neither jq nor python3 found; skipped $ROOK_HOOK_AGENT hook setup." ;;
    *:failed)
      err "Could not merge $ROOK_HOOK_AGENT hooks — its config is not valid JSON. Left it untouched." ;;
  esac
done <<EOF
$("$HOME/.local/bin/rook-hooks" install)
EOF

# ─── live link ───────────────────────────────────────────────────────
# rook-link holds a WebSocket to roost once `rook connect` names one: it
# sends the agents' events and types prompts from Rookery and from other
# agents into their panes. It needs the websockets package, installed into
# a virtual environment of rook's own, and runs as a user service that
# idles until connected.
echo ""
echo "── live link ─────────────────────────────────────"

ROOK_VENV="$HOME/.local/share/rook/venv"
ROOK_WEBSOCKETS_SPEC='websockets>=13,<17'
ROOK_LINK_READY=1
if [ ! -x "$ROOK_VENV/bin/python" ] && ! python3 -m venv "$ROOK_VENV"; then
  warn "Could not create $ROOK_VENV (on Debian: apt install python3-venv); rook-link stays off"
  ROOK_LINK_READY=0
fi
if [ "$ROOK_LINK_READY" -eq 1 ] &&
  ! "$ROOK_VENV/bin/python" -m pip install --quiet --disable-pip-version-check "$ROOK_WEBSOCKETS_SPEC"; then
  warn "Could not install $ROOK_WEBSOCKETS_SPEC into $ROOK_VENV; rook-link stays off"
  ROOK_LINK_READY=0
fi

ROOK_LINK_LABEL="io.github.zobinhuang.rookery.rook-link"
ROOK_LINK_LOG="$HOME/.local/state/rook/link.log"
if [ "$ROOK_LINK_READY" -eq 0 ]; then
  :
elif [ "$ROOK_DO_SERVICE" -eq 0 ]; then
  info "rook-link installed; not started as a service (--no-service)"
elif [ "$(uname -s)" = "Darwin" ]; then
  ROOK_LINK_PLIST="$HOME/Library/LaunchAgents/$ROOK_LINK_LABEL.plist"
  mkdir -p "$(dirname "$ROOK_LINK_PLIST")" "$(dirname "$ROOK_LINK_LOG")"
  cat > "$ROOK_LINK_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$ROOK_LINK_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ROOK_VENV/bin/python</string>
    <string>$HOME/.local/bin/rook-link</string>
    <string>run</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>$PATH</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$ROOK_LINK_LOG</string>
  <key>StandardErrorPath</key><string>$ROOK_LINK_LOG</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$ROOK_LINK_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$ROOK_LINK_PLIST"
  info "Started launchd agent $ROOK_LINK_LABEL"
elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  ROOK_LINK_UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$ROOK_LINK_UNIT_DIR"
  cat > "$ROOK_LINK_UNIT_DIR/rook-link.service" <<UNIT
[Unit]
Description=rook's live link to roost
After=network-online.target

[Service]
ExecStart=$ROOK_VENV/bin/python $HOME/.local/bin/rook-link run
Environment=PATH=$PATH
Environment=HOME=$HOME
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
UNIT
  # By its full path: the user manager looks for units under the home it
  # knows, which is not $HOME where a machine moves home elsewhere.
  if systemctl --user daemon-reload &&
    systemctl --user enable "$ROOK_LINK_UNIT_DIR/rook-link.service" >/dev/null 2>&1 &&
    systemctl --user restart rook-link.service; then
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 ||
      warn "Could not enable lingering; rook-link stops when you log out."
    info "Started systemd user unit rook-link.service"
  else
    warn "Could not start rook-link as a systemd user unit; start it by hand:"
    warn "  nohup $ROOK_VENV/bin/python $HOME/.local/bin/rook-link run >> $ROOK_LINK_LOG 2>&1 &"
  fi
else
  warn "No launchd or systemd; start the link by hand:"
  warn "  nohup $ROOK_VENV/bin/python $HOME/.local/bin/rook-link run >> $ROOK_LINK_LOG 2>&1 &"
fi

# ─── 6. hot reload ───────────────────────────────────────────────────
echo ""
echo "── reload ────────────────────────────────────────"

# Everything under ~/.local/bin re-executes from scratch on every call,
# so those are live the moment they're written. The tmux config is the
# exception: a running server holds its own copy of every binding,
# format and hook, so sessions open right now would keep the old ones
# until they were restarted. Push the new config in instead.
#
# Repeating this is safe. Every line in the config replaces rather than
# appends — which is exactly why the sync hooks use `set-hook -g`; with
# `-ga` each re-source would stack another copy and every event would
# fire sync N times. The agent rows survive too, because status-format
# holds an indirection (`#{E:@rook-row-...}`) rather than the template
# itself, so live sessions pick up new row rendering for free.
#
# Code-agent hooks need nothing here: both Claude Code and codex re-read
# their hook config mid-session (codex asks you to re-trust it first).
if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
  ROOK_LIVE="$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')"
  if tmux source-file "$TMUX_CONF" 2>/dev/null; then
    "$HOME/.local/bin/rook-agent" sync >/dev/null 2>&1 || true
    info "Reloaded into $ROOK_LIVE running session(s) — no restart needed"
  else
    warn "Could not reload the running tmux server."
    warn "Run this by hand to finish the upgrade: tmux source-file ~/.tmux.conf"
  fi
else
  info "No running tmux session to reload"
fi

# Agents that were already running when this ran have just been given the
# upload hooks, but nothing would push them until their next turn — and
# codex will not fire a hook at all until its new config is trusted. Push
# what is already under way instead of waiting. Nothing happens here if
# this machine was never connected to a session server.
if [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/rook/connect.json" ]; then
  nohup "$HOME/.local/bin/rook-session" adopt --quiet >/dev/null 2>&1 &
  info "Pushing agent sessions already under way to the session server"
fi

# ─── done ─────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "  Setup complete!"
echo ""
echo "  Sessions:"
echo "    rook new <name>          Create a new session"
echo "    rook attach <name>       Attach to existing session"
echo "    rook ls                  List all sessions"
echo "    rook kill <name>         Kill a session"
echo "    rook exit                Kill current session"
echo "    rook connect <host> <port> --token <token>"
echo "                             Upload session history to a roost server"
echo ""
echo "  Tabs (Ctrl+t):          Panes (Ctrl+p):"
echo "    n   new tab              d   split down"
echo "    r   rename tab           n   split right"
echo "    ←/→ switch tab           ←/→/↑/↓ navigate"
echo "    x   close tab            x   close pane"
echo "    c   clear stuck tab      z   toggle fullscreen"
echo "    p   pick playbook"
echo ""
echo "  Resize (Ctrl+n):  h/j/k/l or arrows (repeatable)"
echo ""
echo "  Alt+left/right:   panes first, then along the status bar,"
echo "                    walking the READY row then the BUSY row."
echo "  Alt+up/down:      panes only."
echo ""
if [ "$ROOK_CODEX_NEEDS_TRUST" -eq 1 ]; then
  echo ""
  echo "  ─────────────────────────────────────────────"
  echo "  ONE MANUAL STEP for codex:"
  echo "    Codex will not run a newly written hook until you have"
  echo "    reviewed it. Open codex and run  /hooks  to trust them,"
  echo "    or the BUSY row will stay empty for codex tabs."
  echo "  ─────────────────────────────────────────────"
fi
echo "══════════════════════════════════════════════════"
echo ""
