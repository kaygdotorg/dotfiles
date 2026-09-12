"""Run the dot dispatcher against copied sources and temporary homes."""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


class DotPathTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dot-paths-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo with spaces"
        self.home = self.root / "home"
        self.home.mkdir()
        for name in ("scripts/dot", "scripts/lib/nix.sh", ".ssh/config", ".ssh/config.local.example"):
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, target)
        self.env = dict(os.environ, HOME=str(self.home), DOT_LOG="")

    def dot(self, *args):
        return subprocess.run(
            ["/bin/bash", str(self.repo / "scripts/dot"), *args],
            env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=20,
        )

    def success(self, *args):
        result = self.dot(*args)
        self.assertEqual(result.returncode, 0, result.stdout)
        return result

    def test_invalid_dispatch_does_not_change_home(self):
        for args in ((), ("setup",), ("delete", "ssh"), ("setup", "unknown"), ("update", "ssh", "unexpected")):
            with self.subTest(args=args):
                self.assertNotEqual(self.dot(*args).returncode, 0)
                self.assertEqual(list(self.home.iterdir()), [])

    def test_dot_link_supports_repeated_setup_and_symlink_invocation(self):
        self.success("setup", "dot")
        link = self.home / ".local/bin/dot"
        self.assertEqual(link.resolve(), (self.repo / "scripts/dot").resolve())
        result = subprocess.run(
            [str(link), "setup", "dot"], env=self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(link.resolve(), (self.repo / "scripts/dot").resolve())

    def test_ssh_setup_and_update_preserve_local_configuration(self):
        ssh = self.home / ".ssh"
        ssh.mkdir()
        (ssh / "config").write_text("previous config\n")
        (ssh / "config.local").write_text("Host test-only\n  User fixture\n")
        self.success("setup", "ssh")
        self.success("update", "ssh")
        self.assertEqual((ssh / "config").resolve(), (self.repo / ".ssh/config").resolve())
        self.assertEqual((ssh / "config.local").read_text(), "Host test-only\n  User fixture\n")
        backups = list(ssh.glob("config.bak.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "previous config\n")
        for path in (ssh, ssh / "sockets"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)

    def test_ssh_directory_link_does_not_modify_its_target(self):
        ssh = self.home / ".ssh"
        ssh.mkdir()
        outside = self.root / "unrelated directory"
        outside.mkdir(mode=0o700)
        (ssh / "config").symlink_to(outside, target_is_directory=True)
        result = self.dot("setup", "ssh")
        actual_mode = stat.S_IMODE(outside.stat().st_mode)
        outside.chmod(0o700)  # Make cleanup reliable even on the buggy implementation.
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(actual_mode, 0o700)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual((ssh / "config").resolve(), (self.repo / ".ssh/config").resolve())

    def test_ssh_dangling_local_link_is_preserved_without_following_it(self):
        ssh = self.home / ".ssh"
        ssh.mkdir()
        outside = self.root / "missing private config"
        (ssh / "config.local").symlink_to(outside)
        result = self.dot("setup", "ssh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue((ssh / "config.local").is_symlink())
        self.assertFalse(outside.exists())

    def test_ssh_local_directory_is_rejected_without_seeding_inside_it(self):
        local = self.home / ".ssh/config.local"
        local.mkdir(parents=True)
        result = self.dot("setup", "ssh")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(list(local.iterdir()), [])

    def karabiner_commands(self, platform, fail_check=False):
        mock_bin = self.root / "mock-bin"
        mock_bin.mkdir(exist_ok=True)
        uname = mock_bin / "uname"
        uname.write_text("#!/bin/sh\nprintf '%s\\n' \"$DOT_TEST_OS\"\n")
        npm = mock_bin / "npm"
        npm.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOT_NPM_LOG"\n'
            'case "$*" in *check*) [ "$DOT_FAIL_CHECK" != yes ] || exit 7 ;; esac\n'
        )
        uname.chmod(0o755)
        npm.chmod(0o755)
        log = self.root / "npm.log"
        log.write_text("")
        self.env.update(
            PATH=str(mock_bin) + os.pathsep + os.environ.get("PATH", ""),
            DOT_TEST_OS=platform, DOT_NPM_LOG=str(log),
            DOT_FAIL_CHECK="yes" if fail_check else "no",
        )
        return log

    def test_karabiner_rejects_linux_before_running_npm(self):
        log = self.karabiner_commands("Linux")
        for action in ("setup", "update"):
            result = self.dot(action, "karabiner")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("macOS only", result.stdout)
        self.assertEqual(log.read_text(), "")

    def test_karabiner_setup_and_update_check_before_generating(self):
        log = self.karabiner_commands("Darwin")
        for action in ("setup", "update"):
            with self.subTest(action=action):
                log.write_text("")
                self.success(action, "karabiner")
                commands = log.read_text().splitlines()
                self.assertEqual(len(commands), 3)
                self.assertTrue(commands[0].startswith("ci --prefix "), commands)
                self.assertTrue(commands[1].endswith(" check"), commands)
                self.assertTrue(commands[2].endswith(" build"), commands)

    def test_karabiner_check_failure_prevents_generation(self):
        log = self.karabiner_commands("Darwin", fail_check=True)
        result = self.dot("setup", "karabiner")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed", result.stdout)
        self.assertFalse(any(line.endswith(" build") for line in log.read_text().splitlines()))

    def git(self, directory, *args):
        return subprocess.run(
            ["git", "-C", str(directory), *args], env=self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=True, timeout=20,
        ).stdout

    def repository_pair(self):
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT"):
            self.env.pop(name, None)
        remote = self.root / "origin.git"
        remote.mkdir()
        self.git(remote, "init", "--bare", "--initial-branch=main")
        self.git(self.repo, "init", "--initial-branch=main")
        self.git(self.repo, "config", "user.name", "Fixture")
        self.git(self.repo, "config", "user.email", "fixture@example.invalid")
        self.git(self.repo, "config", "pull.rebase", "true")
        (self.repo / "settings.txt").write_text("base\n")
        self.git(self.repo, "add", ".")
        self.git(self.repo, "commit", "-m", "fixture")
        self.git(self.repo, "remote", "add", "origin", str(remote))
        self.git(self.repo, "push", "-u", "origin", "main")
        peer = self.root / "peer"
        self.git(self.root, "clone", str(remote), str(peer))
        self.git(peer, "config", "user.name", "Fixture")
        self.git(peer, "config", "user.email", "fixture@example.invalid")
        return peer

    def test_dot_update_keeps_local_edits_when_pull_succeeds(self):
        peer = self.repository_pair()
        (peer / "remote.txt").write_text("upstream\n")
        self.git(peer, "add", "remote.txt")
        self.git(peer, "commit", "-m", "upstream")
        self.git(peer, "push")
        (self.repo / "settings.txt").write_text("my local edit\n")
        self.success("update", "dot")
        self.assertEqual((self.repo / "settings.txt").read_text(), "my local edit\n")
        self.assertEqual((self.repo / "remote.txt").read_text(), "upstream\n")

    def test_dot_update_reports_autostash_conflicts_as_failure(self):
        peer = self.repository_pair()
        (peer / "settings.txt").write_text("upstream edit\n")
        self.git(peer, "commit", "-am", "upstream")
        self.git(peer, "push")
        (self.repo / "settings.txt").write_text("my local edit\n")
        result = self.dot("update", "dot")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("conflicts", result.stdout)
        self.assertIn("settings.txt", self.git(self.repo, "diff", "--name-only", "--diff-filter=U"))
        self.assertIn("my local edit", (self.repo / "settings.txt").read_text())
        self.assertIn("autostash", self.git(self.repo, "stash", "list"))


if __name__ == "__main__":
    unittest.main()
