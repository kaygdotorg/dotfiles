"""Test agent installation orchestration with isolated homes and vendor doubles."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class AgentsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dot-agents-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home with spaces"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "events"
        self.log.write_text("")
        self.env = dict(os.environ, HOME=str(self.home), DOT_TEST_LOG=str(self.log),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        TMPDIR=str(self.root), DOT_LOG="")
        self.mock("id", '#!/bin/sh\nprintf "1000\\n"\n')
        self.mock("uname", '#!/bin/sh\ncase "$1" in -s) echo "${DOT_TEST_OS:-Linux}" ;; -m) echo "${DOT_TEST_ARCH:-x86_64}" ;; esac\n')
        self.mock("curl", r'''#!/bin/bash
set -eu
url= output=
while [ "$#" -gt 0 ]; do
    case "$1" in
        https://*) url="$1"; shift ;;
        --output) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'download %s\n' "$url" >> "$DOT_TEST_LOG"
[ "${DOT_TEST_DOWNLOAD_FAIL:-}" != "$url" ] || exit 23
case "$url" in
    https://claude.ai/install.sh) agent=claude ;;
    https://chatgpt.com/codex/install.sh) agent=codex ;;
    https://antigravity.google/cli/install.sh) agent=agy ;;
    *) exit 99 ;;
esac
[ "${DOT_TEST_EMPTY:-}" != "$agent" ] || { : > "$output"; exit 0; }
cat > "$output" <<INSTALL
#!/bin/sh
set -eu
printf 'install $agent\n' >> "\$DOT_TEST_LOG"
[ "\${DOT_TEST_INSTALL_FAIL:-}" != "$agent" ] || exit 7
mkdir -p "\$HOME/.local/bin"
cat > "\$HOME/.local/bin/$agent" <<'BINARY'
#!/bin/sh
printf '$agent %s\n' "\$*" >> "\$DOT_TEST_LOG"
[ "\${DOT_TEST_UPDATE_FAIL:-}" != "$agent" ] || exit 8
BINARY
chmod +x "\$HOME/.local/bin/$agent"
INSTALL
''')
        # An unrelated sudo must never be invoked by an agent installation.
        self.mock("sudo", '#!/bin/sh\necho sudo >> "$DOT_TEST_LOG"\nexit 99\n')

    def mock(self, name, text):
        path = self.bin / name
        path.write_text(text)
        path.chmod(0o755)

    def dot(self, action="setup"):
        return subprocess.run([str(REPO / "scripts/dot"), action, "agents"],
                              env=self.env, text=True, capture_output=True, timeout=20)

    def success(self, action="setup"):
        result = self.dot(action)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("sudo", self.log.read_text())

    def test_setup_installs_native_tools_once_on_supported_platforms(self):
        for system, arch in (("Linux", "x86_64"), ("Linux", "aarch64"), ("Darwin", "arm64")):
            with self.subTest(system=system):
                shutil.rmtree(self.home / ".local", ignore_errors=True)
                self.log.write_text("")
                self.env.update(DOT_TEST_OS=system, DOT_TEST_ARCH=arch)
                self.success()
                events = self.log.read_text()
                for agent in ("claude", "codex", "agy"):
                    self.assertIn("install " + agent, events)
                    self.assertTrue(os.access(self.home / ".local/bin" / agent, os.X_OK))
                self.success()
                self.assertEqual(self.log.read_text(), events)

    def test_update_uses_vendor_updaters_and_codex_installer(self):
        self.success()
        self.log.write_text("")
        self.success("update")
        events = self.log.read_text()
        self.assertIn("claude update", events)
        self.assertIn("agy update", events)
        self.assertIn("install codex", events)
        self.assertNotIn("install claude", events)
        self.assertNotIn("install agy", events)

    def test_update_bootstraps_missing_agents(self):
        self.success("update")
        events = self.log.read_text()
        for agent in ("claude", "codex", "agy"):
            self.assertEqual(events.count("install " + agent), 1)

    def test_download_and_installer_failures_stop_and_remove_temporary_files(self):
        cases = (("DOT_TEST_DOWNLOAD_FAIL", "https://claude.ai/install.sh"),
                 ("DOT_TEST_EMPTY", "claude"), ("DOT_TEST_INSTALL_FAIL", "claude"))
        for key, value in cases:
            with self.subTest(key=key):
                self.log.write_text("")
                self.env[key] = value
                self.assertNotEqual(self.dot().returncode, 0)
                self.assertNotIn("install codex", self.log.read_text())
                self.assertFalse(list(self.root.glob("dot-agents.*")))
                self.env.pop(key)

    def test_update_failure_is_reported_and_stops_later_updates(self):
        self.success()
        self.log.write_text("")
        self.env["DOT_TEST_UPDATE_FAIL"] = "claude"
        self.assertNotEqual(self.dot("update").returncode, 0)
        self.assertNotIn("install codex", self.log.read_text())
        self.assertNotIn("agy update", self.log.read_text())

    def test_store_symlink_is_removed_without_changing_its_target(self):
        native = self.home / ".local/bin"
        native.mkdir(parents=True)
        target = self.root / "pretend-store-binary"
        target.write_text("#!/bin/sh\nexit 99\n")
        target.chmod(0o755)
        (native / "claude").symlink_to(target)
        real_realpath = shutil.which("realpath")
        self.mock("realpath", '#!/bin/sh\n'
                  'if [ "$1" = "$HOME/.local/bin/claude" ] && [ -L "$1" ]; then\n'
                  ' echo /nix/store/mock/claude\nelse\n'
                  + ' exec "' + real_realpath + '" "$@"\nfi\n')
        self.success()
        self.assertFalse((native / "claude").is_symlink())
        self.assertEqual(target.read_text(), "#!/bin/sh\nexit 99\n")

    def test_unsupported_host_fails_before_installing_anything(self):
        self.env["DOT_TEST_OS"] = "FreeBSD"
        self.assertNotEqual(self.dot().returncode, 0)
        self.assertEqual(self.log.read_text(), "")
