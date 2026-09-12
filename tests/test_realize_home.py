"""Policy tests for nix/realize_home.py.

The tests use command doubles throughout.  They intentionally never invoke
Nix, Home Manager, activation scripts, or codesign on the live machine.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Any, Sequence
from unittest.mock import patch


import sys


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "nix"))

import realize_home as rh  # noqa: E402


class FakeNix(rh.Nix):
    def __init__(
        self,
        graph: rh.DerivationGraph,
        *,
        fail_cache: bool = False,
        cache_error: str = "substitute unavailable",
    ) -> None:
        super().__init__(runner=rh.CommandRunner(run=self._command))
        self.graph = graph
        self.fail_cache = fail_cache
        self.cache_error = cache_error
        self.builds: list[tuple[int, tuple[str, ...]]] = []
        self.commands: list[list[str]] = []

    def _command(self, argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess[str]:
        args = list(argv)
        self.commands.append(args)
        if args[:2] == ["nix", "--version"]:
            return subprocess.CompletedProcess(args, 0, "nix (Determinate Nix) 2.35.2\n", "")
        if args[:3] == ["nix", "profile", "rollback"]:
            return subprocess.CompletedProcess(args, 0, "", "")
        return subprocess.CompletedProcess(args, 0, "", "")

    def version(self) -> tuple[int, int, int]:
        return (2, 35, 2)

    def derivation_show(self, drv_paths: Sequence[str], recursive: bool = False) -> rh.DerivationGraph:
        return self.graph

    def build(self, selectors: Sequence[str], max_jobs: int) -> None:
        self.builds.append((max_jobs, tuple(selectors)))
        if self.fail_cache and max_jobs == 0:
            raise rh.CommandError(("nix", "build", *selectors), 1, "", self.cache_error)


def node(
    drv_path: str,
    output_path: str | None,
    *,
    inputs: dict[str, list[str]] | None = None,
) -> rh.Derivation:
    raw: dict[str, Any] = {"outputs": {"out": {}}}
    if output_path is not None:
        raw["outputs"] = {"out": {"path": output_path}}
    if inputs:
        raw["inputs"] = {
            "drvs": {
                path: {"outputs": outputs}
                for path, outputs in inputs.items()
            }
        }
    return rh.Derivation(drv_path=drv_path, raw=raw)


def deployment(
    *,
    activation_drv: str = "/nix/store/activation.drv",
    activation_path: str = "/nix/store/activation",
    cached: tuple[rh.Artifact, ...] = (),
    local: tuple[rh.Artifact, ...] = (),
    migration: dict[str, Any] | None = None,
) -> rh.Deployment:
    return rh.Deployment(
        system="x86_64-linux",
        home_directory="/home/kayg",
        activation=rh.Activation(activation_drv, activation_path),
        cached=cached,
        local=local,
        migration=migration or {},
    )


class RealizeHomeTests(unittest.TestCase):
    def test_determinate_version_uses_upstream_version(self) -> None:
        calls: list[list[str]] = []

        def command(argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess[str]:
            calls.append(list(argv))
            return subprocess.CompletedProcess(
                list(argv),
                0,
                "nix (Determinate Nix 3.22.1) 2.35.2\n",
                "",
            )

        nix = rh.Nix(runner=rh.CommandRunner(run=command))
        self.assertEqual(nix.version(), (2, 35, 2))

    def test_nix_235_graph_normalizes_keys_and_selected_multi_output(self) -> None:
        payload = {
            "version": 4,
            "derivations": {
                "abc123-ghostty-bin.drv": {
                    "outputs": {
                        "out": {},
                        "terminfo": {},
                    },
                    "env": {
                        "out": "/nix/store/out-ghostty",
                        "terminfo": "/nix/store/terminfo-ghostty",
                    },
                    "inputs": {
                        "drvs": {
                            "def456-source.drv": {
                                "dynamicOutputs": {},
                                "outputs": ["out"],
                            }
                        }
                    },
                },
                "def456-source.drv": {
                    "outputs": {"out": {}},
                    "env": {"out": "/nix/store/source"},
                },
            },
        }
        graph = rh.DerivationGraph.from_json(payload)
        artifact = rh.Artifact(
            "ghostty-terminfo",
            "/nix/store/abc123-ghostty-bin.drv",
            ("/nix/store/terminfo-ghostty",),
        )

        self.assertEqual(
            rh.selectors_for(artifact, graph),
            (("terminfo", "/nix/store/terminfo-ghostty"),),
        )
        self.assertEqual(
            graph.get(artifact.drv_path).inputs(),
            (("/nix/store/def456-source.drv", ("out",)),),
        )

    def test_cache_miss_never_falls_back_to_an_ordinary_build(self) -> None:
        cached = rh.Artifact("cached-tool", "/nix/store/cached.drv", ("/tmp/missing-cached",))
        graph = rh.DerivationGraph(
            {
                cached.drv_path: node(cached.drv_path, cached.outputs[0]),
                "/nix/store/activation.drv": node("/nix/store/activation.drv", "/nix/store/activation"),
            }
        )
        nix = FakeNix(graph, fail_cache=True)
        realizer = rh.Realizer(deployment=cached_deployment(cached), nix=nix, output=io.StringIO())
        realizer.graph = graph

        with self.assertRaisesRegex(rh.RealizeHomeError, "cache-only fetch failed"):
            realizer.realize_cached(cached)
        self.assertEqual([jobs for jobs, _ in nix.builds], [0])
        self.assertNotIn(1, [jobs for jobs, _ in nix.builds])

    def test_missing_derivation_is_reported_as_cache_fetch_failure(self) -> None:
        cached = rh.Artifact("homeassistant-cli", "/nix/store/missing.drv", ("/tmp/missing",))
        graph = rh.DerivationGraph(
            {
                cached.drv_path: node(cached.drv_path, cached.outputs[0]),
                "/nix/store/activation.drv": node("/nix/store/activation.drv", "/nix/store/activation"),
            }
        )
        missing_error = "failed to obtain derivation '/nix/store/missing.drv'"
        nix = FakeNix(graph, fail_cache=True, cache_error=missing_error)
        realizer = rh.Realizer(deployment=cached_deployment(cached), nix=nix, output=io.StringIO())
        realizer.graph = graph

        with self.assertRaises(rh.RealizeHomeError) as raised:
            realizer.realize_cached(cached)
        message = str(raised.exception)
        self.assertIn("cache-only fetch failed", message)
        self.assertNotIn("cache miss", message)
        self.assertIn(missing_error, message)
        self.assertEqual(nix.builds, [(0, ("/nix/store/missing.drv^out",))])

    def test_only_exact_local_drv_paths_get_positive_jobs(self) -> None:
        local = rh.Artifact("reviewed-wrapper", "/nix/store/reviewed.drv", ())
        graph = rh.DerivationGraph(
            {
                "/nix/store/activation.drv": node("/nix/store/activation.drv", "/nix/store/activation"),
                local.drv_path: node(local.drv_path, "/tmp/reviewed"),
            }
        )
        nix = FakeNix(graph)
        realizer = rh.Realizer(deployment=deployment(local=(local,)), nix=nix, output=io.StringIO())
        realizer.run()

        positive = [selectors for jobs, selectors in nix.builds if jobs > 0]
        self.assertEqual(len(positive), 2)  # activation and the one reviewed local entry
        self.assertTrue(all(selector.startswith("/nix/store/") and "^." not in selector for group in positive for selector in group))
        with self.assertRaisesRegex(rh.RealizeHomeError, "unallowlisted"):
            realizer.realize_local(
                rh.Artifact("same-looking-name", "/nix/store/unreviewed.drv", ()),
            )

    def test_unknown_module_dependency_is_cache_only_and_fails(self) -> None:
        local = rh.Artifact("hm-generated", "/nix/store/local.drv", ())
        graph = rh.DerivationGraph(
            {
                "/nix/store/activation.drv": node("/nix/store/activation.drv", "/tmp/activation"),
                local.drv_path: node(
                    local.drv_path,
                    "/tmp/local",
                    inputs={"/nix/store/unknown-module.drv": ["out"]},
                ),
                "/nix/store/unknown-module.drv": node(
                    "/nix/store/unknown-module.drv",
                    "/tmp/unknown",
                ),
            }
        )
        nix = FakeNix(graph, fail_cache=True)
        realizer = rh.Realizer(deployment=deployment(local=(local,)), nix=nix, output=io.StringIO())
        realizer.graph = graph

        with self.assertRaisesRegex(rh.RealizeHomeError, "cache-only fetch failed for dependency"):
            realizer.realize_local(local)
        self.assertEqual([jobs for jobs, _ in nix.builds], [0])

    def test_unknown_dynamic_dependency_metadata_is_rejected(self) -> None:
        derivation = rh.Derivation(
            "/nix/store/local.drv",
            {
                "outputs": {"out": {"path": "/tmp/local"}},
                "inputs": {
                    "drvs": {
                        "/nix/store/dynamic.drv": {
                            "outputs": ["out"],
                            "dynamicOutputs": {"unknown": "value"},
                        }
                    }
                },
            },
        )
        with self.assertRaisesRegex(rh.DeploymentError, "dynamic outputs"):
            derivation.inputs()

    def test_partial_output_information_is_never_considered_available(self) -> None:
        self.assertFalse(rh._paths_available(("/tmp/does-not-exist", None)))

    def test_activation_failure_restores_old_hm_before_profile_rollback(self) -> None:
        calls: list[list[str]] = []

        def command(argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess[str]:
            args = list(argv)
            calls.append(args)
            if args and args[0] == "/tmp/new-generation/activate":
                return subprocess.CompletedProcess(args, 1, "", "new activation failed")
            if args and args[0] == "/tmp/old-generation/activate":
                return subprocess.CompletedProcess(args, 1, "", "old activation failed")
            return subprocess.CompletedProcess(args, 0, "", "")

        old_activation_prefix = ""
        with tempfile.TemporaryDirectory() as temp:
            hm_link = Path(temp) / "home-manager"
            old_target = Path(temp) / "old-generation"
            old_activation_prefix = str(old_target)
            hm_link.symlink_to(old_target)
            runner = rh.CommandRunner(run=command)
            nix = rh.Nix(runner=runner)
            snapshot = rh.ProfileSnapshot(
                profile_path=Path(temp) / "profile",
                profile_target="/nix/store/profile",
                profile_generation=23,
                hm_links=((hm_link, str(old_target)),),
            )

            with self.assertRaisesRegex(rh.RealizeHomeError, "rollback was attempted"):
                rh.activate_with_rollback(
                    deployment(),
                    nix,
                    "/tmp/new-generation",
                    snapshot,
                    output=io.StringIO(),
                )

        self.assertEqual(calls[0][0], "/tmp/new-generation/activate")
        self.assertEqual(calls[1][0], f"{old_activation_prefix}/activate")
        self.assertEqual(
            calls[-1],
            ["nix", "profile", "rollback", "--profile", str(snapshot.profile_path), "--to", "23"],
        )

    def test_check_only_evaluates_and_does_not_realize_or_activate(self) -> None:
        class CheckNix(FakeNix):
            def __init__(self) -> None:
                super().__init__(rh.DerivationGraph({}))
                self.evaluated = False

            def eval_deployment(self, flake: str, host: str) -> dict[str, Any]:
                self.evaluated = True
                return {
                    "system": "x86_64-linux",
                    "homeDirectory": "/home/kayg",
                    "activation": {
                        "drvPath": "/nix/store/activation.drv",
                        "path": "/nix/store/activation",
                    },
                    "cached": [],
                    "local": [],
                    "migration": {},
                }

            def version(self) -> tuple[int, int, int]:
                raise AssertionError("check mode must not query Nix version")

            def derivation_show(self, drv_paths: Sequence[str], recursive: bool = False) -> rh.DerivationGraph:
                raise AssertionError("check mode must not query the derivation graph")

            def build(self, selectors: Sequence[str], max_jobs: int) -> None:
                raise AssertionError("check mode must not build")

        nix = CheckNix()
        result = rh.main(
            [
                "--flake",
                "/tmp/flake",
                "--host",
                "kayg",
                "--check",
                "--before-activate",
                "/tmp/should-not-run.sh",
            ],
            nix=nix,
            output=io.StringIO(),
        )
        self.assertEqual(result, 0)
        self.assertTrue(nix.evaluated)

    def test_migration_requires_exact_attrpath_and_original_url(self) -> None:
        migration = {
            "caddy": {
                "attrPath": "legacyPackages.aarch64-darwin.caddy",
                "originalUrls": ["flake:nixpkgs"],
            }
        }
        entries = [
            {
                "name": "caddy",
                "attrPath": "legacyPackages.aarch64-darwin.caddy",
                "originalUrl": "flake:nixpkgs",
            },
            {
                "name": "keep-me",
                "attrPath": "legacyPackages.aarch64-darwin.caddy",
                "originalUrl": "other-flake",
            },
        ]
        self.assertEqual(rh.migration_removals(migration, entries, report=io.StringIO()), ("caddy",))

    def test_fresh_install_skips_migration_without_a_default_profile(self) -> None:
        migration = {
            "old-tool": {
                "attrPath": "legacyPackages.aarch64-darwin.old-tool",
                "originalUrls": ["flake:nixpkgs"],
            }
        }
        nix = FakeNix(rh.DerivationGraph({}))
        report = io.StringIO()
        snapshot = rh.ProfileSnapshot(
            profile_path=None,
            profile_target=None,
            profile_generation=None,
            hm_links=(),
        )

        self.assertEqual(
            rh.migrate_profile(
                deployment(migration=migration),
                nix,
                snapshot,
                output=report,
            ),
            (),
        )
        self.assertIn("no default Nix profile exists yet", report.getvalue())
        self.assertEqual(nix.commands, [])

    def test_snapshot_follows_legacy_nix_profile_chain(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / "home"
            global_profiles = root / "nix" / "profiles" / "per-user" / "kayg"
            home.mkdir()
            global_profiles.mkdir(parents=True)
            mutable_profile = global_profiles / "profile"
            generation_link = global_profiles / "profile-52-link"
            generation_link.symlink_to(root / "store-profile")
            mutable_profile.symlink_to(generation_link.name)
            (home / ".nix-profile").symlink_to(mutable_profile)

            snapshot = rh.snapshot_profiles(
                {
                    "HOME": str(home),
                    "XDG_STATE_HOME": str(root / "state"),
                }
            )

        self.assertEqual(snapshot.profile_path, mutable_profile)
        self.assertEqual(snapshot.profile_generation, 52)
        self.assertEqual(snapshot.profile_target, os.path.realpath(root / "store-profile"))

    def test_existing_profile_without_generation_refuses_migration(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            home = root / "home"
            global_profiles = root / "nix" / "profiles" / "per-user" / "kayg"
            home.mkdir()
            global_profiles.mkdir(parents=True)
            mutable_profile = global_profiles / "profile"
            mutable_profile.symlink_to(root / "store-profile")
            (home / ".nix-profile").symlink_to(mutable_profile)
            snapshot = rh.snapshot_profiles(
                {
                    "HOME": str(home),
                    "XDG_STATE_HOME": str(root / "state"),
                }
            )
            nix = FakeNix(rh.DerivationGraph({}))
            migration = {
                "old-tool": {
                    "attrPath": "legacyPackages.aarch64-darwin.old-tool",
                    "originalUrls": ["flake:nixpkgs"],
                }
            }

            with self.assertRaisesRegex(rh.RealizeHomeError, "numeric generation"):
                rh.migrate_profile(deployment(migration=migration), nix, snapshot)
            self.assertEqual(nix.commands, [])

    def test_duplicate_exact_migration_entries_fail_closed(self) -> None:
        migration = {
            "caddy": {
                "attrPath": "legacyPackages.aarch64-darwin.caddy",
                "originalUrls": ["flake:nixpkgs"],
            }
        }
        entry = {
            "name": "caddy",
            "attrPath": "legacyPackages.aarch64-darwin.caddy",
            "originalUrl": "flake:nixpkgs",
        }
        with self.assertRaisesRegex(rh.RealizeHomeError, "collision"):
            rh.migration_removals(migration, [entry, dict(entry)], report=io.StringIO())

    def test_wrong_host_is_rejected_before_realization(self) -> None:
        class HostNix(FakeNix):
            def __init__(self) -> None:
                super().__init__(rh.DerivationGraph({}))
                self.evaluated = False

            def eval_deployment(self, flake: str, host: str) -> dict[str, Any]:
                self.evaluated = True
                return {
                    "system": rh.current_system(),
                    "homeDirectory": "/definitely/not-the-current-home",
                    "activation": {
                        "drvPath": "/nix/store/activation.drv",
                        "path": "/nix/store/activation",
                    },
                    "cached": [],
                    "local": [],
                    "migration": {},
                }

            def version(self) -> tuple[int, int, int]:
                raise AssertionError("host mismatch must precede Nix version checks")

        nix = HostNix()
        self.assertEqual(
            rh.main(["--flake", "/tmp/flake", "--host", "wrong"], nix=nix, output=io.StringIO()),
            1,
        )
        self.assertTrue(nix.evaluated)
        self.assertEqual(nix.builds, [])

    def test_failing_before_activate_guard_prevents_profile_and_activation(self) -> None:
        class GuardNix(FakeNix):
            def _command(self, argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess[str]:
                args = list(argv)
                self.commands.append(args)
                if args and Path(args[0]).name == "bash":
                    return subprocess.CompletedProcess(args, 1, "", "source changed")
                return subprocess.CompletedProcess(args, 0, "", "")

        activation = "/nix/store/activation.drv"
        graph = rh.DerivationGraph(
            {activation: node(activation, "/nix/store/activation")}
        )
        nix = GuardNix(graph)
        current = rh.Deployment(
            system=rh.current_system(),
            home_directory=os.environ["HOME"],
            activation=rh.Activation(activation, "/nix/store/activation"),
            migration={
                "managed": {
                    "attrPath": "legacyPackages.test.managed",
                    "originalUrls": ["flake:test"],
                }
            },
        )
        guard = tempfile.NamedTemporaryFile(mode="w", suffix=".sh", delete=False)
        guard.close()
        try:
            class GuardMainNix(GuardNix):
                def eval_deployment(self, flake: str, host: str) -> dict[str, Any]:
                    return {
                        "system": current.system,
                        "homeDirectory": current.home_directory,
                        "activation": {
                            "drvPath": current.activation.drv_path,
                            "path": current.activation.path,
                        },
                        "cached": [],
                        "local": [],
                        "migration": dict(current.migration),
                    }

            nix = GuardMainNix(graph)
            result = rh.main(
                [
                    "--flake",
                    "/tmp/flake",
                    "--host",
                    "kayg",
                    "--before-activate",
                    guard.name,
                ],
                nix=nix,
                output=io.StringIO(),
            )
        finally:
            Path(guard.name).unlink(missing_ok=True)

        self.assertEqual(result, 1)
        self.assertEqual(len(nix.commands), 1)
        self.assertEqual(Path(nix.commands[0][0]).name, "bash")
        self.assertFalse(any(call[:2] == ["nix", "profile"] for call in nix.commands))
        self.assertFalse(any(call and call[0].endswith("/activate") for call in nix.commands))

    def test_before_activate_resolves_bash_from_path(self) -> None:
        calls: list[list[str]] = []

        def command(argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess[str]:
            calls.append(list(argv))
            return subprocess.CompletedProcess(list(argv), 0, "", "")

        with tempfile.TemporaryDirectory() as temp:
            bash = Path(temp) / "bash"
            bash.write_text("#!/bin/sh\nexit 0\n")
            bash.chmod(0o755)
            rh.run_before_activate_hook(
                "/tmp/source-guard",
                rh.CommandRunner(run=command),
                output=io.StringIO(),
                environ={"PATH": temp},
            )

        self.assertEqual(calls, [[str(bash), "/tmp/source-guard"]])

    def test_before_activate_reports_missing_bash_without_running_guard(self) -> None:
        calls: list[list[str]] = []

        def command(argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess[str]:
            calls.append(list(argv))
            return subprocess.CompletedProcess(list(argv), 0, "", "")

        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(rh.RealizeHomeError, "requires an executable bash on PATH"):
                rh.run_before_activate_hook(
                    "/tmp/source-guard",
                    rh.CommandRunner(run=command),
                    output=io.StringIO(),
                    environ={"PATH": temp},
                )

        self.assertEqual(calls, [])

    def test_guard_rechecks_after_migration_and_rolls_back_when_source_changes(self) -> None:
        calls: list[list[str]] = []
        state = {"source_changed": False}

        class MigrationNix(rh.Nix):
            def __init__(self) -> None:
                super().__init__(runner=rh.CommandRunner(run=self._command))

            def _command(self, argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess[str]:
                args = list(argv)
                calls.append(args)
                if args and Path(args[0]).name == "bash" and state["source_changed"]:
                    return subprocess.CompletedProcess(args, 1, "", "source changed")
                return subprocess.CompletedProcess(args, 0, "", "")

            def profile_list(self, profile_path: Path | str | None = None) -> list[dict[str, str]]:
                calls.append(["nix", "profile", "list", str(profile_path)])
                return [
                    {
                        "name": "managed",
                        "attrPath": "legacyPackages.test.managed",
                        "originalUrl": "flake:test",
                    }
                ]

            def profile_remove(self, names: Sequence[str], profile_path: Path | str | None = None) -> None:
                calls.append(["nix", "profile", "remove", *names, str(profile_path)])
                # Simulate the updater observing a source edit while profile
                # migration is mutating the old generation.
                state["source_changed"] = True

            def profile_rollback(self, generation: int, profile_path: Path | str | None = None) -> None:
                calls.append(["nix", "profile", "rollback", str(profile_path), str(generation)])

        nix = MigrationNix()
        manifest = {
            "managed": {
                "attrPath": "legacyPackages.test.managed",
                "originalUrls": ["flake:test"],
            }
        }
        current = deployment(migration=manifest)
        profile_path = Path("/tmp/realize-home-profile")
        snapshot = rh.ProfileSnapshot(
            profile_path=profile_path,
            profile_target="/nix/store/profile",
            profile_generation=8,
            hm_links=((Path("/tmp/home-manager"), "/tmp/old-generation"),),
        )

        rh.run_before_activate_hook("/tmp/source-guard", nix.runner, output=io.StringIO())
        self.assertEqual(rh.migrate_profile(current, nix, snapshot, output=io.StringIO()), ("managed",))
        with self.assertRaisesRegex(rh.RealizeHomeError, "rollback was attempted"):
            rh.activate_with_rollback(
                current,
                nix,
                "/tmp/new-generation",
                snapshot,
                before_activate_script="/tmp/source-guard",
                output=io.StringIO(),
            )

        bash_calls = [call for call in calls if call and Path(call[0]).name == "bash"]
        self.assertEqual(len(bash_calls), 2)
        self.assertIn(["nix", "profile", "remove", "managed", str(profile_path)], calls)
        self.assertIn(["/tmp/old-generation/activate"], calls)
        self.assertIn(["nix", "profile", "rollback", str(profile_path), "8"], calls)
        self.assertNotIn(["/tmp/new-generation/activate"], calls)
        self.assertLess(calls.index(["/tmp/old-generation/activate"]), calls.index(["nix", "profile", "rollback", str(profile_path), "8"]))

    def test_nix_build_uses_unique_private_gc_root_out_links(self) -> None:
        calls: list[list[str]] = []

        def command(argv: Sequence[str], **_: Any) -> subprocess.CompletedProcess[str]:
            args = list(argv)
            calls.append(args)
            out_link = Path(args[args.index("--out-link") + 1])
            out_link.symlink_to("/nix/store/fake-result")
            return subprocess.CompletedProcess(args, 0, "", "")

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "gc-roots"
            nix = rh.Nix(runner=rh.CommandRunner(run=command), gc_root_dir=root)
            nix.build(
                ["/nix/store/first.drv^out", "/nix/store/second.drv^terminfo"],
                max_jobs=0,
            )

            self.assertEqual(len(calls), 2)
            links = []
            for call in calls:
                self.assertEqual(call[0:2], ["nix", "build"])
                self.assertIn(["--max-jobs", "0"], [call[i : i + 2] for i in range(len(call) - 1)])
                link = Path(call[call.index("--out-link") + 1])
                links.append(link)
                self.assertEqual(link.parent, root)
                self.assertTrue(link.is_symlink())
            self.assertNotEqual(links[0], links[1])

    def test_existing_dependency_hit_is_rooted_before_local_parent_build(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            dependency_output = root / "dependency"
            dependency_output.write_text("already in the store fixture")
            local = rh.Artifact("reviewed-parent", "/nix/store/local.drv", ())
            graph = rh.DerivationGraph(
                {
                    local.drv_path: node(
                        local.drv_path,
                        str(root / "local-output"),
                        inputs={"/nix/store/dependency.drv": ["out"]},
                    ),
                    "/nix/store/dependency.drv": node(
                        "/nix/store/dependency.drv",
                        str(dependency_output),
                    ),
                    "/nix/store/activation.drv": node(
                        "/nix/store/activation.drv",
                        str(root / "activation-output"),
                    ),
                }
            )
            nix = FakeNix(graph)
            realizer = rh.Realizer(deployment=deployment(local=(local,)), nix=nix, output=io.StringIO())
            realizer.graph = graph

            realizer.realize_local(local)

        self.assertEqual(
            nix.builds,
            [
                (0, ("/nix/store/dependency.drv^out",)),
                (1, ("/nix/store/local.drv^out",)),
            ],
        )

    def test_gc_root_lives_through_activation_then_is_cleaned(self) -> None:
        activation_drv = "/nix/store/activation.drv"
        graph = rh.DerivationGraph({activation_drv: node(activation_drv, "/tmp/activation")})

        class RootNix(FakeNix):
            def eval_deployment(self, flake: str, host: str) -> dict[str, Any]:
                return {
                    "system": rh.current_system(),
                    "homeDirectory": os.environ["HOME"],
                    "activation": {
                        "drvPath": activation_drv,
                        "path": "/tmp/activation",
                    },
                    "cached": [],
                    "local": [],
                    "migration": {},
                }

        nix = RootNix(graph)
        observed_roots: list[Path] = []

        def activation(path: str, runner: rh.CommandRunner) -> subprocess.CompletedProcess[str]:
            self.assertIsNotNone(nix.gc_root_dir)
            assert nix.gc_root_dir is not None
            self.assertTrue(nix.gc_root_dir.is_dir())
            observed_roots.append(nix.gc_root_dir)
            return subprocess.CompletedProcess([str(Path(path) / "activate")], 0, "", "")

        empty_snapshot = rh.ProfileSnapshot(None, None, None, ())
        with patch.object(rh, "snapshot_profiles", return_value=empty_snapshot), patch.object(
            rh, "_activate_path", side_effect=activation
        ):
            result = rh.main(
                ["--flake", "/tmp/flake", "--host", "kayg"],
                nix=nix,
                output=io.StringIO(),
            )

        self.assertEqual(result, 0)
        self.assertEqual(len(observed_roots), 1)
        self.assertFalse(observed_roots[0].exists())
        self.assertIsNone(nix.gc_root_dir)

    def test_wrapper_bootstraps_when_system_python_is_too_old(self) -> None:
        script = REPO_ROOT / "nix" / "realize-home"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            store = root / "python-store"
            fetched_python = store / "bin" / "python3"
            fetched_python.parent.mkdir(parents=True)
            fetched_log = root / "fetched-python.args"
            fetched_python.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$@\" > {fetched_log}\n"
            )
            fetched_python.chmod(0o755)

            old_python = fake_bin / "python3"
            old_python.write_text("#!/bin/sh\nexit 1\n")
            old_python.chmod(0o755)
            fake_nix = fake_bin / "nix"
            fake_nix.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  --version) printf '%s\\n' 'nix (Determinate Nix) 2.35.2' ;;\n"
                f"  build) printf '%s\\n' '{store}' ;;\n"
                "  *) exit 1 ;;\n"
                "esac\n"
            )
            fake_nix.chmod(0o755)

            environment = dict(os.environ)
            environment["PATH"] = f"{fake_bin}:/bin:/usr/bin"
            result = subprocess.run(
                ["bash", str(script), "--flake", "/tmp/flake", "--host", "kayg"],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                fetched_log.read_text().splitlines(),
                [str(REPO_ROOT / "nix" / "realize_home.py"), "--flake", "/tmp/flake", "--host", "kayg"],
            )

    def test_wrapper_puts_fallback_nix_on_path_for_usable_python(self) -> None:
        script = REPO_ROOT / "nix" / "realize-home"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            python_bin = root / "python-bin"
            fallback_bin = root / "fallback-bin"
            python_bin.mkdir()
            fallback_bin.mkdir()
            nix_log = root / "nix.args"
            deployment_json = json.dumps(
                {
                    "system": rh.current_system(),
                    "homeDirectory": os.environ["HOME"],
                    "activation": {
                        "drvPath": "/nix/store/activation.drv",
                        "path": "/nix/store/activation",
                    },
                    "cached": [],
                    "local": [],
                    "migration": {},
                }
            )
            fallback_nix = fallback_bin / "nix"
            fallback_nix.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"$@\" > {nix_log}\n"
                f"if [ \"$1\" = eval ]; then printf '%s\\n' '{deployment_json}'; fi\n"
            )
            fallback_nix.chmod(0o755)
            usable_python = python_bin / "python3"
            usable_python.write_text(
                "#!/bin/sh\n"
                f"exec \"{sys.executable}\" \"$@\"\n"
            )
            usable_python.chmod(0o755)

            environment = dict(os.environ)
            environment["PATH"] = f"{python_bin}:/bin:/usr/bin"
            environment["REALIZE_HOME_NIX"] = str(fallback_nix)
            result = subprocess.run(
                ["bash", str(script), "--flake", "/tmp/flake", "--host", "kayg", "--check"],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(nix_log.read_text().splitlines()[0], "eval")


def cached_deployment(cached: rh.Artifact) -> rh.Deployment:
    return deployment(cached=(cached,))


if __name__ == "__main__":
    unittest.main()
