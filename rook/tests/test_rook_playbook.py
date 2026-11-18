import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from rook.tests import test_rook_client
from rook.tests.test_rook_client import REPO_ROOT, RookHomeTest

PLAYBOOK_TOOL = REPO_ROOT / "rook" / "bin" / "rook-playbook"
REAL_TMUX = shutil.which("tmux")
SHIM = """#!/bin/sh
case "$1" in
  set-option|show-options)
    if [ "$ROOK_TEST_OLD_TMUX" = 1 ]; then
      for argument in "$@"; do
        if [ "$argument" = -p ]; then
          echo "unknown option -- p" >&2
          exit 1
        fi
      done
    fi
    ;;
  list-commands)
    if [ "$ROOK_TEST_OLD_TMUX" = 1 ]; then
      "$ROOK_TEST_REAL_TMUX" -S "$ROOK_TEST_SOCKET" list-commands | grep -v '^display-popup'
      exit 0
    fi
    ;;
esac
exec "$ROOK_TEST_REAL_TMUX" -S "$ROOK_TEST_SOCKET" "$@"
"""


@unittest.skipIf(REAL_TMUX is None, "needs tmux")
class PlaybookPaneTest(RookHomeTest):
    """A playbook bound to a pane and told to its agent, on a tmux with pane options and on one without,
    as tmux before 3.0 is: an isolated tmux server, its old self played by a shim that refuses them."""

    TEST_TOKEN = test_rook_client.QueueAndSendTest.TEST_TOKEN

    def setUp(self) -> None:
        super().setUp()
        server = test_rook_client.QueueAndSendTest.start_server(self)
        server.catalog.create("playbook", {"id": "review", "name": "Review", "prompt": "Check every diff twice.", "skills": []})
        test_rook_client.QueueAndSendTest.connect(self, server.server_address[1])
        self.socket_dir = Path(tempfile.mkdtemp(dir="/tmp", prefix="rk"))
        self.addCleanup(shutil.rmtree, self.socket_dir, True)
        socket = self.socket_dir / "t.sock"
        shim_dir = self.socket_dir / "bin"
        shim_dir.mkdir()
        (shim_dir / "tmux").write_text(SHIM)
        (shim_dir / "tmux").chmod(0o755)
        self.project = self.home / "project"
        self.project.mkdir()
        self.map_environment = {
            key: value for key, value in os.environ.items() if key not in ("TMUX", "TMUX_PANE")
        }
        self.map_environment.update({
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / "config"),
            "XDG_STATE_HOME": str(self.home / "state"),
            "XDG_DATA_HOME": str(self.home / "data"),
            "TMUX_TMPDIR": str(self.socket_dir),
            "PATH": f"{shim_dir}:{os.environ['PATH']}",
            "ROOK_TEST_REAL_TMUX": str(REAL_TMUX),
            "ROOK_TEST_SOCKET": str(socket),
        })
        self.tmux(["-f", "/dev/null", "new-session", "-d", "-s", "t", "-x", "80", "-y", "24", "sleep 600"])
        self.addCleanup(self.tmux, ["kill-server"])
        self.pane = self.tmux(["display-message", "-p", "-t", "t", "#{pane_id}"]).strip()

    def tmux(self, list_arguments: list[str]) -> str:
        return subprocess.run(
            ["tmux", *list_arguments],
            env=self.map_environment,
            capture_output=True,
            text=True,
            check=False,
        ).stdout

    def playbook(self, list_arguments: list[str], stdin: str = "", pane: str | None = None) -> subprocess.CompletedProcess[str]:
        map_environment = dict(self.map_environment)
        if pane:
            map_environment["TMUX_PANE"] = pane
        return subprocess.run(
            ["sh", str(PLAYBOOK_TOOL), *list_arguments],
            input=stdin,
            env=map_environment,
            capture_output=True,
            text=True,
            check=False,
            cwd=self.socket_dir,
        )

    def install_and_tell(self) -> None:
        installed = self.playbook(["install", "review", "--agent", "claude", "--project", str(self.project), "--pane", self.pane, "--quiet"])
        self.assertEqual(installed.returncode, 0, installed.stderr)
        self.assertEqual(self.playbook(["current", "--pane", self.pane]).stdout.strip(), "review")
        payload = json.dumps({"session_id": "s-1", "cwd": str(self.project)})
        told = self.playbook(["context", "claude"], stdin=payload, pane=self.pane)
        map_context = json.loads(told.stdout)["hookSpecificOutput"]
        self.assertIn("Check every diff twice.", map_context["additionalContext"])
        self.assertEqual(self.playbook(["context", "claude"], stdin=payload, pane=self.pane).stdout, "")

    def test_a_tmux_with_pane_options_keeps_the_playbook_on_the_pane(self) -> None:
        self.install_and_tell()
        self.assertIn("review", self.tmux(["show-options", "-p", "-t", self.pane]))
        self.assertFalse((self.home / "state" / "rook" / "pane-options").exists())

    def test_a_tmux_without_pane_options_keeps_it_in_a_file_and_still_tells_the_agent(self) -> None:
        self.map_environment["ROOK_TEST_OLD_TMUX"] = "1"
        self.install_and_tell()
        list_files = sorted(path.name for path in (self.home / "state" / "rook" / "pane-options").iterdir())
        server_pid = self.tmux(["display-message", "-p", "-t", self.pane, "#{pid}"]).strip()
        pane_number = self.pane.lstrip("%")
        self.assertEqual(list_files, [
            f"{server_pid}-{pane_number}.rook-playbook-injected",
            f"{server_pid}-{pane_number}.rook-playbook-pane",
        ])
        self.playbook(["uninstall", "--agent", "claude", "--project", str(self.project), "--pane", self.pane])
        self.assertEqual(self.playbook(["current", "--pane", self.pane]).stdout.strip(), "")

    def test_an_install_the_pane_cannot_keep_fails_rather_than_pass_for_loaded(self) -> None:
        self.map_environment["ROOK_TEST_OLD_TMUX"] = "1"
        (self.home / "state" / "rook").mkdir(parents=True, exist_ok=True)
        (self.home / "state" / "rook" / "pane-options").write_text("not a directory")
        installed = self.playbook(["install", "review", "--agent", "claude", "--project", str(self.project), "--pane", self.pane, "--quiet"])
        self.assertNotEqual(installed.returncode, 0)
        self.assertIn("cannot record playbook", installed.stderr)


if __name__ == "__main__":
    unittest.main()
