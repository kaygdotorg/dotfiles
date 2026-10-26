"""Exercise the real tmux config on a private socket and temporary home."""

import os
import fcntl
import pty
from pathlib import Path
import shlex
import shutil
import subprocess
import struct
import termios
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
TMUX = shutil.which("tmux")


@unittest.skipUnless(TMUX, "tmux is required for configuration checks")
class TmuxTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dot-tmux-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.socket = str(self.home / "socket")
        self.config = self.home / ".config/tmux"
        self.config.mkdir(parents=True)
        for source in (REPO / "tmux").iterdir():
            name = "tmux.conf" if source.name == ".tmux.conf" else source.name
            (self.config / name).symlink_to(source)
        # Helpers must use the isolated server, including when invoked directly.
        bin_dir = self.home / "bin"
        bin_dir.mkdir()
        wrapper = bin_dir / "tmux"
        wrapper.write_text(
            "#!/bin/sh\nexec " + shlex.quote(TMUX) + " -S "
            + shlex.quote(self.socket) + ' "$@"\n'
        )
        wrapper.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home), TMUX="",
                        PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
        self.addCleanup(self.stop_server)
        self.tmux("-f", "/dev/null", "new-session", "-d", "-s", "work", "/bin/sh")

    def stop_server(self):
        subprocess.run([TMUX, "-S", self.socket, "kill-server"], env=self.env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def tmux(self, *args):
        result = subprocess.run([TMUX, "-S", self.socket, *args], env=self.env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def reload(self):
        self.tmux("source-file", str(self.config / "tmux.conf"))
        # Wait for background helpers without arbitrary delays.
        self.tmux("run-shell", "true")

    def test_config_reloads_without_tpm_and_preserves_terminal_defaults(self):
        self.tmux("set-option", "-as", "terminal-overrides", ",testterm:Tc")
        self.reload()
        features = self.tmux("show-options", "-sv", "terminal-features")
        self.reload()
        self.assertEqual(self.tmux("show-options", "-gv", "prefix"), "C-t")
        self.assertIn("testterm:Tc", self.tmux("show-options", "-sv", "terminal-overrides"))
        self.assertEqual(features, self.tmux("show-options", "-sv", "terminal-features"))
        for table in ("root", "off"):
            for key in ("F12", "M-F"):
                self.assertIn(key, self.tmux("list-keys", "-T", table))

    def test_extended_keys_opt_in_survives_reload(self):
        self.reload()
        self.assertEqual(self.tmux("show-options", "-sv", "extended-keys"), "off")
        self.tmux("set-option", "-g", "@extended-keys", "on")
        self.reload()
        self.assertEqual(self.tmux("show-options", "-sv", "extended-keys"), "on")
        self.assertEqual(self.tmux("show-options", "-sv", "extended-keys-format"), "csi-u")
        self.tmux("set-option", "-g", "@extended-keys", "off")
        self.reload()
        self.assertEqual(self.tmux("show-options", "-sv", "extended-keys"), "off")
        self.assertEqual(self.tmux("show-options", "-gwv", "copy-mode-line-numbers"), "hybrid")

    def test_attached_client_can_toggle_keys_and_search_scrollback(self):
        self.reload()
        self.tmux("set-hook", "-g", "client-attached[99]", "wait-for -S attached")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        client = subprocess.Popen(
            [TMUX, "-S", self.socket, "attach-session", "-t", "work"],
            env=dict(self.env, TERM="xterm-256color"), stdin=slave, stdout=slave,
            stderr=slave, start_new_session=True,
        )
        try:
            self.tmux("wait-for", "attached")
            name = self.tmux("list-clients", "-F", "#{client_name}")
            # -K sends keys through the client's actual key tables.
            self.tmux("send-keys", "-K", "-c", name, "C-t", "E")
            self.assertEqual(self.tmux("show-options", "-sv", "extended-keys"), "on")
            self.tmux("send-keys", "-K", "-c", name, "C-t", "E")
            self.assertEqual(self.tmux("show-options", "-sv", "extended-keys"), "off")
            self.tmux("copy-mode", "-t", "work")
            self.tmux("send-keys", "-K", "-c", name, "/")
            self.tmux("send-keys", "-K", "-c", name, "needle", "Enter")
            self.assertEqual(self.tmux("display-message", "-p", "-t", "work:",
                                       "#{pane_search_string}"), "needle")
        finally:
            self.stop_server()
            # A client can block writing its final screen to an unread PTY.
            client.terminate()
            os.close(slave)
            os.close(master)
            client.wait(timeout=10)

    def test_picker_switches_existing_sessions_creates_projects_and_cancels(self):
        # fzf chooses a label; real tmux creates sessions on the private socket.
        # Log switch-client because this test runs without an attached terminal.
        bin_dir = self.home / "bin"
        wrapper = bin_dir / "tmux"
        switch_log = self.home / "switch-target"
        wrapper.write_text(
            "#!/bin/sh\nif [ \"$1\" = switch-client ]; then\n"
            + '  printf "%s\\n" "$3" > ' + shlex.quote(str(switch_log)) + "\n  exit 0\nfi\n"
            + "exec " + shlex.quote(TMUX) + " -S " + shlex.quote(self.socket) + ' "$@"\n'
        )
        fzf = bin_dir / "fzf"
        fzf.write_text(
            "#!/usr/bin/env python3\nimport os, sys\n"
            "rows = sys.stdin.readlines()\n"
            "match = os.environ.get('DOT_PICK_MATCH')\n"
            "if not match: sys.exit(130)\n"
            "print(next(row for row in rows if match in row), end='')\n"
        )
        fzf.chmod(0o755)
        roots = self.home / "projects"
        roots.mkdir()
        project = roots / "spaces; $(touch should-not-exist) #{pid}"
        project.mkdir()
        environment = dict(self.env, DOT_PROJECT_ROOTS=str(roots))
        script = str(self.config / "session-picker.py")

        def pick(match):
            subprocess.run([script], env=dict(environment, DOT_PICK_MATCH=match),
                           cwd=self.home, check=True, timeout=15)

        pick("session  work")
        self.assertEqual(switch_log.read_text().strip(), "$0")
        pick("project  ")
        target = switch_log.read_text().strip()
        self.assertTrue(target.startswith("="))
        self.assertEqual(self.tmux("list-panes", "-t", target, "-F", "#{pane_current_path}"), str(project))
        before = self.tmux("list-sessions", "-F", "#{session_id}")
        pick("project  ")  # Reuses the exact session instead of making duplicates.
        self.assertEqual(self.tmux("list-sessions", "-F", "#{session_id}"), before)
        switch_log.unlink()
        pick("")
        self.assertFalse(switch_log.exists())
        self.assertEqual(self.tmux("list-sessions", "-F", "#{session_id}"), before)
        self.assertFalse((self.home / "should-not-exist").exists())

    def test_tuning_tracks_height_and_remote_environment_by_session_id(self):
        self.reload()
        session = self.tmux("display-message", "-p", "#{session_id}")
        self.tmux("rename-session", "-t", session, "work with spaces; literal $name")
        self.tmux("set-environment", "-t", session, "SSH_CONNECTION", "test")
        for height, rows in ((20, "on"), (40, "2"), (20, "on")):
            result = subprocess.run([str(self.config / "client-tune.sh"), str(height), session],
                                    env=self.env, text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.tmux("show-options", "-v", "-t", session, "status"), rows)
            self.assertEqual(self.tmux("show-options", "-v", "-t", session, "status-position"), "bottom")
        self.tmux("set-environment", "-r", "-t", session, "SSH_CONNECTION")
        subprocess.run([str(self.config / "client-tune.sh"), "40", session],
                       env=self.env, check=True, timeout=15)
        self.assertEqual(self.tmux("show-options", "-v", "-t", session, "status-position"), "top")


@unittest.skipUnless(shutil.which("zsh"), "zsh is required for autostart checks")
class AutostartTests(unittest.TestCase):
    def test_autostart_requires_interactive_tty_and_respects_escape_hatches(self):
        with tempfile.TemporaryDirectory(prefix="dot-automux-") as root:
            home = Path(root)
            (home / ".config/tmux").mkdir(parents=True)
            bin_dir = home / "bin"
            bin_dir.mkdir()
            log = home / "calls"
            mock = bin_dir / "tmux"
            mock.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOT_TEST_CALLS"\n'
                'case "$1" in has-session) exit 1 ;; esac\n'
            )
            mock.chmod(0o755)
            source = (REPO / "zsh/.zshrc").read_text()
            start = source.index("if [[ $- == *i* ]] && [[ -t 0 && -t 1 ]]")
            end = source.index("# History", start)
            fixture = home / "autostart.zsh"
            fixture.write_text(source[start:end])
            environment = dict(os.environ, HOME=root, DOT_TEST_CALLS=str(log),
                               PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])
            for name in ("TMUX", "TMUX_CLIENT_NAME", "DOT_NO_AUTOMUX", "SSH_ORIGINAL_COMMAND"):
                environment.pop(name, None)
            cases = [(True, True, {}, True), (False, True, {}, False),
                     (True, False, {}, False)]
            cases += [(True, True, {name: "test"}, False) for name in
                      ("TMUX", "DOT_NO_AUTOMUX", "SSH_ORIGINAL_COMMAND")]
            for interactive, tty, extra, expected in cases:
                with self.subTest(interactive=interactive, tty=tty, extra=extra):
                    log.write_text("")
                    args = [shutil.which("zsh"), "-df" + ("i" if interactive else ""), str(fixture)]
                    master, slave = pty.openpty()
                    try:
                        result = subprocess.run(args, env=dict(environment, **extra),
                                                stdin=slave if tty else subprocess.DEVNULL,
                                                stdout=slave if tty else subprocess.DEVNULL,
                                                stderr=subprocess.PIPE, timeout=15)
                    finally:
                        os.close(slave)
                        os.close(master)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    if expected:
                        self.assertIn("new-session -s work", log.read_text())
                    else:
                        self.assertEqual(log.read_text(), "")
