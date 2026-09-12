#!/usr/bin/env python3
"""Realize a Home Manager deployment without accidentally compiling inputs.

The flake publishes a small, reviewed deployment manifest.  This program is
deliberately conservative: package entries are fetched from substituters with
zero local build jobs, and the only derivations that may be built locally are
the exact ``drvPath`` values in ``deployment.<host>.local`` (plus activation).
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


MIN_NIX_VERSION = (2, 35, 0)
STORE_DIR = "/nix/store"


class RealizeHomeError(RuntimeError):
    """An expected, user-actionable deployment failure."""


class DeploymentError(RealizeHomeError):
    """The flake did not produce a safe deployment manifest."""


class CommandError(RealizeHomeError):
    """A subprocess returned a non-zero status."""

    def __init__(
        self,
        argv: Sequence[str],
        returncode: int,
        stdout: str = "",
        stderr: str = "",
    ) -> None:
        self.argv = tuple(argv)
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr
        detail = (stderr or stdout).strip()
        command = " ".join(argv)
        message = f"command failed ({returncode}): {command}"
        if detail:
            message += f"\n{detail}"
        super().__init__(message)


def _as_nonempty_string(value: Any, field_name: str) -> str:
    if not isinstance(value, str) or not value:
        raise DeploymentError(f"deployment field {field_name!r} must be a non-empty string")
    return value


def _as_string_list(value: Any, field_name: str) -> tuple[str, ...]:
    if value is None:
        return ()
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise DeploymentError(f"deployment field {field_name!r} must be a list of strings")
    return tuple(value)


def _normalise_store_path(value: str, store_dir: str = STORE_DIR) -> str:
    """Turn the abbreviated paths emitted by ``nix derivation show`` absolute."""

    if value.startswith("/"):
        return value
    return f"{store_dir.rstrip('/')}/{value}"


@dataclass(frozen=True)
class Artifact:
    name: str
    drv_path: str
    outputs: tuple[str, ...] = ()


@dataclass(frozen=True)
class Activation:
    drv_path: str
    path: str


@dataclass(frozen=True)
class Deployment:
    system: str
    home_directory: str
    activation: Activation
    cached: tuple[Artifact, ...] = ()
    local: tuple[Artifact, ...] = ()
    migration: Mapping[str, Any] = field(default_factory=dict)


def _artifact(raw: Any, field_name: str) -> Artifact:
    if not isinstance(raw, Mapping):
        raise DeploymentError(f"deployment {field_name} entry must be an object")
    name = _as_nonempty_string(raw.get("name"), f"{field_name}.name")
    drv_path = _as_nonempty_string(raw.get("drvPath"), f"{field_name}.drvPath")
    if not drv_path.endswith(".drv"):
        raise DeploymentError(f"deployment {field_name}.drvPath must end in .drv: {drv_path}")
    outputs = _as_string_list(raw.get("outputs", []), f"{field_name}.outputs")
    return Artifact(name=name, drv_path=drv_path, outputs=outputs)


def _artifact_list(raw: Any, field_name: str) -> tuple[Artifact, ...]:
    if raw is None:
        return ()
    if not isinstance(raw, list):
        raise DeploymentError(f"deployment field {field_name!r} must be a list")
    return tuple(_artifact(item, f"{field_name}[{index}]") for index, item in enumerate(raw))


def _activation(raw: Any, local: Sequence[Artifact]) -> Activation:
    # Early manifests used the activation output path directly.  Keep reading
    # that form so an already-evaluated deployment remains inspectable while
    # requiring a reviewed exact drvPath in the current form.
    if isinstance(raw, str):
        path = raw
        matches = [item for item in local if path in item.outputs]
        if len(matches) != 1:
            raise DeploymentError(
                "legacy activation path must match exactly one local artifact; "
                f"got {path!r} and {len(matches)} matches"
            )
        return Activation(drv_path=matches[0].drv_path, path=path)

    if not isinstance(raw, Mapping):
        raise DeploymentError("deployment activation must be an object")
    drv_path = _as_nonempty_string(raw.get("drvPath"), "activation.drvPath")
    if not drv_path.endswith(".drv"):
        raise DeploymentError(f"activation.drvPath must end in .drv: {drv_path}")
    path_value = raw.get("path", raw.get("outPath"))
    path = _as_nonempty_string(path_value, "activation.path")
    return Activation(drv_path=drv_path, path=path)


def parse_deployment(raw: Any) -> Deployment:
    """Validate the deployment output and convert it to typed records."""

    if not isinstance(raw, Mapping):
        raise DeploymentError("deployment output must be a JSON object")
    system = _as_nonempty_string(raw.get("system"), "system")
    home_directory = _as_nonempty_string(raw.get("homeDirectory"), "homeDirectory")
    cached = _artifact_list(raw.get("cached", []), "cached")
    local = _artifact_list(raw.get("local", []), "local")
    activation = _activation(raw.get("activation"), local)
    migration = raw.get("migration", {})
    if not isinstance(migration, Mapping):
        raise DeploymentError("deployment field 'migration' must be an object")

    # The allowlist is intentionally keyed by exact derivation path.  Duplicate
    # paths with different records make a safe plan impossible.
    records: dict[str, tuple[str, str]] = {}
    for group, entries in (("cached", cached), ("local", local)):
        for item in entries:
            previous = records.get(item.drv_path)
            identity = (group, item.name)
            if previous is not None and previous != identity:
                raise DeploymentError(
                    f"drvPath appears more than once with conflicting identities: {item.drv_path}"
                )
            records[item.drv_path] = identity
    if activation.drv_path in records and records[activation.drv_path][0] == "cached":
        raise DeploymentError("activation drvPath cannot also be a cached-only artifact")

    return Deployment(
        system=system,
        home_directory=home_directory,
        activation=activation,
        cached=cached,
        local=local,
        migration=migration,
    )


class CommandRunner:
    """Small subprocess adapter that is easy to replace in tests."""

    def __init__(self, run=subprocess.run) -> None:
        self._run = run

    def run(
        self,
        argv: Sequence[str],
        *,
        check: bool = True,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        try:
            result = self._run(
                list(argv),
                check=False,
                input=input_text,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except OSError as exc:
            raise RealizeHomeError(f"could not run {' '.join(argv)}: {exc}") from exc
        if check and result.returncode:
            raise CommandError(argv, result.returncode, result.stdout or "", result.stderr or "")
        return result


def cache_only_options() -> list[str]:
    """Options that make a Nix invocation substitute-only."""

    return [
        "--max-jobs",
        "0",
        "--option",
        "builders",
        "",
        "--option",
        "allow-import-from-derivation",
        "false",
        "--option",
        "external-builders",
        "[]",
    ]


def local_build_options() -> list[str]:
    """Options for the reviewed local derivation allowlist."""

    options = cache_only_options()
    options[1] = "1"
    return options


def _selector(drv_path: str, output_name: str) -> str:
    if not output_name or output_name == "*" or any(char.isspace() for char in output_name):
        raise DeploymentError(f"invalid derivation output selector {output_name!r} for {drv_path}")
    # Never pass a bare .drv or ^* selector: both can realize more than the
    # reviewed output set.
    return f"{drv_path}^{output_name}"


@dataclass(frozen=True)
class Derivation:
    drv_path: str
    raw: Mapping[str, Any]
    store_dir: str = STORE_DIR

    @property
    def outputs(self) -> Mapping[str, Any]:
        raw_outputs = self.raw.get("outputs", {})
        return raw_outputs if isinstance(raw_outputs, Mapping) else {}

    def output_path(self, name: str) -> str | None:
        data = self.outputs.get(name)
        if isinstance(data, str):
            return _normalise_store_path(data, self.store_dir)
        if isinstance(data, Mapping):
            path = data.get("path")
            if isinstance(path, str) and path:
                return _normalise_store_path(path, self.store_dir)
        # Nix 2.35 omits the path for fixed-output derivations in ``outputs``;
        # it remains available in the environment under the output name.
        env = self.raw.get("env", {})
        if isinstance(env, Mapping):
            path = env.get(name)
            if isinstance(path, str) and path.startswith("/"):
                return path
        return None

    def output_names(self) -> tuple[str, ...]:
        names = tuple(str(name) for name in self.outputs)
        return names or ("out",)

    def inputs(self) -> tuple[tuple[str, tuple[str, ...]], ...]:
        # Nix 2.35 emits ``inputs.drvs``.  Older Nix releases used
        # ``inputDrvs`` directly; accepting both makes this parser useful in
        # fixture-based tests and for a cached derivation dump.
        candidates: Any = self.raw.get("inputDrvs")
        if candidates is None:
            inputs = self.raw.get("inputs", {})
            candidates = inputs.get("drvs", {}) if isinstance(inputs, Mapping) else {}
        if not isinstance(candidates, Mapping):
            return ()

        result: list[tuple[str, tuple[str, ...]]] = []
        for raw_drv, raw_outputs in candidates.items():
            if not isinstance(raw_drv, str) or not raw_drv:
                continue
            drv = _normalise_store_path(raw_drv, self.store_dir)
            if isinstance(raw_outputs, Mapping):
                dynamic_outputs = raw_outputs.get("dynamicOutputs", {})
                if dynamic_outputs not in ({}, [], None):
                    raise DeploymentError(
                        f"dynamic outputs are not supported for dependency {drv}; "
                        "refusing an unreviewed local build"
                    )
                output_values = raw_outputs.get("outputs", [])
            else:
                output_values = raw_outputs
            if isinstance(output_values, str):
                output_names = (output_values,)
            elif isinstance(output_values, list):
                output_names = tuple(item for item in output_values if isinstance(item, str) and item)
            else:
                output_names = ()
            result.append((drv, output_names or ("out",)))
        return tuple(result)


@dataclass(frozen=True)
class DerivationGraph:
    derivations: Mapping[str, Derivation]
    store_dir: str = STORE_DIR

    @classmethod
    def from_json(cls, raw: Any) -> "DerivationGraph":
        if not isinstance(raw, Mapping):
            raise DeploymentError("nix derivation show returned a non-object JSON value")
        store_dir = raw.get("storeDir") if isinstance(raw.get("storeDir"), str) else STORE_DIR
        entries = raw.get("derivations", raw)
        if not isinstance(entries, Mapping):
            raise DeploymentError("nix derivation show JSON has no derivations object")
        derivations: dict[str, Derivation] = {}
        for raw_drv, data in entries.items():
            if not isinstance(raw_drv, str) or not isinstance(data, Mapping):
                continue
            drv_path = _normalise_store_path(raw_drv, store_dir)
            derivation = Derivation(drv_path=drv_path, raw=data, store_dir=store_dir)
            # Validate this metadata while the graph is being loaded so a
            # dynamic dependency cannot be hidden behind an already-present
            # store output and skipped during traversal.
            derivation.inputs()
            derivations[drv_path] = derivation
        return cls(derivations=derivations, store_dir=store_dir)

    def merge(self, other: "DerivationGraph") -> "DerivationGraph":
        merged = dict(self.derivations)
        merged.update(other.derivations)
        return DerivationGraph(derivations=merged, store_dir=self.store_dir)

    def get(self, drv_path: str) -> Derivation | None:
        return self.derivations.get(_normalise_store_path(drv_path, self.store_dir))


class Nix:
    def __init__(
        self,
        runner: CommandRunner | None = None,
        executable: str = "nix",
        gc_root_dir: Path | None = None,
    ) -> None:
        self.runner = runner or CommandRunner()
        self.executable = executable
        self.gc_root_dir = gc_root_dir
        self._out_link_counter = 0

    def _run(self, args: Sequence[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
        return self.runner.run([self.executable, *args], check=check)

    def eval_deployment(self, flake: str, host: str) -> Mapping[str, Any]:
        result = self._run(
            [
                "eval",
                "--json",
                "--no-write-lock-file",
                "--option",
                "allow-import-from-derivation",
                "false",
                f"{flake}#deployment.{host}",
            ]
        )
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise DeploymentError(f"nix eval returned invalid deployment JSON: {exc}") from exc
        if not isinstance(value, Mapping):
            raise DeploymentError("nix eval deployment result is not an object")
        return value

    def derivation_show(self, drv_paths: Sequence[str], recursive: bool = False) -> DerivationGraph:
        if not drv_paths:
            return DerivationGraph(derivations={})
        args = ["derivation", "show"]
        if recursive:
            args.append("--recursive")
        args.extend(drv_paths)
        result = self._run(args)
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise DeploymentError(f"nix derivation show returned invalid JSON: {exc}") from exc
        return DerivationGraph.from_json(value)

    def build(self, selectors: Sequence[str], max_jobs: int) -> None:
        if not selectors:
            return
        for selector in selectors:
            if ".drv^" not in selector or selector.endswith("^*"):
                raise DeploymentError(f"refusing unscoped build selector: {selector}")
        if self.gc_root_dir is None:
            raise RealizeHomeError(
                "refusing an unrooted Nix build; realization must retain a private GC root"
            )
        self.gc_root_dir.mkdir(parents=True, exist_ok=True)
        options = cache_only_options() if max_jobs == 0 else local_build_options()
        # Keep one out-link per selector.  Besides making each exact output a
        # GC root, this avoids relying on Nix's multi-result out-link naming.
        for selector in selectors:
            out_link = self.gc_root_dir / f"result-{self._out_link_counter}"
            self._out_link_counter += 1
            args = ["build", "--out-link", str(out_link), *options, selector]
            self._run(args)

    def version(self) -> tuple[int, int, int]:
        result = self._run(["--version"])
        text = f"{result.stdout}\n{result.stderr}"
        matches = re.findall(r"(?<![0-9])([0-9]+)\.([0-9]+)(?:\.([0-9]+))?", text)
        if not matches:
            raise RealizeHomeError(f"could not determine Nix version from: {text.strip()}")
        # Determinate Nix includes its own product version before the upstream
        # Nix version (for example ``3.22.1 ... 2.35.2``).  The final version
        # tuple is the one that controls the local-build guard.
        return tuple(int(part or 0) for part in matches[-1])  # type: ignore[return-value]

    def profile_list(self, profile_path: Path | str | None = None) -> list[Mapping[str, Any]]:
        args = ["profile", "list"]
        if profile_path is not None:
            args.extend(["--profile", str(profile_path)])
        args.append("--json")
        result = self._run(args)
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise RealizeHomeError(f"nix profile list returned invalid JSON: {exc}") from exc
        if not isinstance(value, Mapping):
            raise RealizeHomeError("nix profile list returned a non-object JSON value")
        elements = value.get("elements", [])
        if isinstance(elements, Mapping):
            result_entries: list[Mapping[str, Any]] = []
            for name, entry in elements.items():
                if isinstance(entry, Mapping):
                    merged = dict(entry)
                    merged.setdefault("name", name)
                    result_entries.append(merged)
            return result_entries
        if isinstance(elements, list):
            return [entry for entry in elements if isinstance(entry, Mapping)]
        return []

    def profile_remove(self, names: Sequence[str], profile_path: Path | str | None = None) -> None:
        if names:
            args = ["profile", "remove"]
            if profile_path is not None:
                args.extend(["--profile", str(profile_path)])
            args.extend(names)
            self._run(args)

    def profile_rollback(self, generation: int, profile_path: Path | str | None = None) -> None:
        args = ["profile", "rollback"]
        if profile_path is not None:
            args.extend(["--profile", str(profile_path)])
        args.extend(["--to", str(generation)])
        self._run(args)


def _requested_output_names(
    artifact: Artifact,
    derivation: Derivation | None,
) -> tuple[tuple[str, str | None], ...]:
    """Return ``(output name, known path)`` for an artifact's selected paths."""

    if derivation is None:
        if artifact.outputs:
            # All flake package outputs are normally ``out``.  A derivation
            # dump is required for local roots and is queried for cached roots
            # when they have multiple outputs, so this fallback only applies to
            # a single output and remains scoped to ^out.
            if len(artifact.outputs) == 1:
                return (("out", artifact.outputs[0]),)
            raise DeploymentError(
                f"cannot map multiple output paths to output names for {artifact.drv_path}"
            )
        return (("out", None),)

    names = derivation.output_names()
    path_to_name: dict[str, str] = {}
    for name in names:
        path = derivation.output_path(name)
        if path:
            path_to_name[path] = name

    if not artifact.outputs:
        return tuple((name, derivation.output_path(name)) for name in names)

    selected: list[tuple[str, str | None]] = []
    for path in artifact.outputs:
        normalised = _normalise_store_path(path, derivation.store_dir)
        name = path_to_name.get(normalised)
        if name is None and path in names:
            name = path
        if name is None:
            raise DeploymentError(
                f"output path {path!r} is not an output of {artifact.drv_path}; refusing ^*"
            )
        selected.append((name, normalised))
    return tuple(selected)


def selectors_for(
    artifact: Artifact,
    graph: DerivationGraph | None = None,
) -> tuple[tuple[str, str | None], ...]:
    derivation = graph.get(artifact.drv_path) if graph else None
    return _requested_output_names(artifact, derivation)


def _paths_available(outputs: Iterable[str | None]) -> bool:
    paths = list(outputs)
    # An unknown output path is not evidence that the output exists.  Treat it
    # as unavailable so the reviewed command either realizes the exact output
    # or fails safely instead of silently considering a partial set complete.
    return bool(paths) and all(isinstance(path, str) and bool(path) and os.path.exists(path) for path in paths)


@dataclass
class Realizer:
    deployment: Deployment
    nix: Nix
    output: Any = sys.stdout
    graph: DerivationGraph | None = None
    _realized: set[tuple[str, tuple[str, ...]]] = field(default_factory=set)
    _in_progress: set[str] = field(default_factory=set)

    def say(self, message: str) -> None:
        print(message, file=self.output)

    @property
    def local_allowlist(self) -> set[str]:
        return {self.deployment.activation.drv_path, *(item.drv_path for item in self.deployment.local)}

    @property
    def local_artifacts(self) -> tuple[Artifact, ...]:
        activation = Artifact(
            name="activation",
            drv_path=self.deployment.activation.drv_path,
            outputs=(self.deployment.activation.path,),
        )
        # Keep the explicit activation record first.  Duplicate local records
        # are rejected by parse_deployment, and an activation record with the
        # same drvPath is harmless because output lookup is deterministic.
        return (activation, *self.deployment.local)

    def prepare_graph(self) -> None:
        local_paths = list(dict.fromkeys(item.drv_path for item in self.local_artifacts))
        self.graph = self.nix.derivation_show(local_paths, recursive=True)

    def prepare_cached_output_graph(self) -> None:
        # The recursive graph is intentionally rooted only at activation/local
        # derivations.  A non-recursive query gives output names for multi-
        # output package records without traversing their upstream graph.
        cached_paths = [item.drv_path for item in self.deployment.cached]
        if not cached_paths:
            return
        cached_graph = self.nix.derivation_show(cached_paths, recursive=False)
        self.graph = (self.graph or DerivationGraph(derivations={})).merge(cached_graph)

    def realize_cached(self, artifact: Artifact) -> None:
        assert self.graph is not None
        selected = selectors_for(artifact, self.graph)
        selector_strings = tuple(_selector(artifact.drv_path, name) for name, _ in selected)
        if _paths_available(path for _, path in selected):
            self.say(f"cached hit: {artifact.name}")
            # Re-root hits as well as substitutes.  A concurrent collector can
            # otherwise remove an existing dependency before an approved
            # local parent is built.
            self.nix.build(selector_strings, max_jobs=0)
            return
        self.say(f"cache-only fetch: {artifact.name}")
        try:
            self.nix.build(selector_strings, max_jobs=0)
        except CommandError as exc:
            raise RealizeHomeError(
                f"cache-only fetch failed for {artifact.name} ({artifact.drv_path}); "
                f"refusing a local build\n{exc}"
            ) from exc

    def _dependency_paths(self, drv_path: str, output_names: Sequence[str]) -> list[str | None]:
        if self.graph is None:
            return [None for _ in output_names]
        derivation = self.graph.get(drv_path)
        if derivation is None:
            return [None for _ in output_names]
        return [derivation.output_path(name) for name in output_names]

    def realize_dependency(self, drv_path: str, output_names: Sequence[str], parent: str) -> None:
        # A dependency already present in the store needs no dependency-graph
        # traversal.  It still gets a cache-only command below so its output
        # remains rooted until the reviewed parent is complete.
        paths = self._dependency_paths(drv_path, output_names)
        selectors = tuple(_selector(drv_path, name) for name in output_names or ("out",))
        if _paths_available(paths):
            # Even a store hit needs a live root until its reviewed parent has
            # finished.  Use the cache-only command so this cannot become a
            # local build through an accidental policy change.
            self.nix.build(selectors, max_jobs=0)
            return

        if drv_path in self.local_allowlist:
            artifact = next(
                (
                    item
                    for item in self.local_artifacts
                    if item.drv_path == drv_path
                ),
                Artifact(name=drv_path, drv_path=drv_path, outputs=()),
            )
            self.realize_local(artifact, output_names=tuple(output_names))
            return

        self.say(f"cache-only dependency: {drv_path}")
        try:
            self.nix.build(selectors, max_jobs=0)
        except CommandError as exc:
            raise RealizeHomeError(
                f"cache-only fetch failed for dependency {drv_path}, required by {parent}; "
                "only reviewed local drvPaths may build locally\n"
                f"{exc}"
            ) from exc

    def realize_local(
        self,
        artifact: Artifact,
        *,
        output_names: Sequence[str] | None = None,
    ) -> None:
        if artifact.drv_path not in self.local_allowlist:
            raise RealizeHomeError(
                f"refusing local build for unallowlisted derivation {artifact.drv_path}"
            )
        if self.graph is None:
            raise RealizeHomeError("local derivation graph was not prepared")
        derivation = self.graph.get(artifact.drv_path)
        if derivation is None:
            raise RealizeHomeError(f"local derivation missing from graph: {artifact.drv_path}")

        selected = selectors_for(artifact, self.graph)
        if output_names is not None:
            names = tuple(output_names) or ("out",)
            selected = tuple((name, derivation.output_path(name)) for name in names)
        key = (artifact.drv_path, tuple(name for name, _ in selected))
        if key in self._realized:
            return
        if artifact.drv_path in self._in_progress:
            raise RealizeHomeError(f"cycle in local derivation inputs at {artifact.drv_path}")
        if _paths_available(path for _, path in selected):
            selector_strings = tuple(_selector(artifact.drv_path, name) for name, _ in selected)
            # Root a local hit before it can be used by another local output.
            self.nix.build(selector_strings, max_jobs=0)
            self._realized.add(key)
            self.say(f"local hit: {artifact.name}")
            return

        self._in_progress.add(artifact.drv_path)
        try:
            for dependency, dependency_outputs in derivation.inputs():
                self.realize_dependency(dependency, dependency_outputs, artifact.drv_path)
            selector_strings = tuple(_selector(artifact.drv_path, name) for name, _ in selected)
            self.say(f"local build: {artifact.name}")
            try:
                self.nix.build(selector_strings, max_jobs=1)
            except CommandError as exc:
                raise RealizeHomeError(
                    f"local build failed for reviewed derivation {artifact.drv_path}\n{exc}"
                ) from exc
            self._realized.add(key)
        finally:
            self._in_progress.discard(artifact.drv_path)

    def plan(self) -> None:
        self.say(
            f"check: {self.deployment.system}, home={self.deployment.home_directory}, "
            f"cached={len(self.deployment.cached)}, local={len(self.deployment.local)}"
        )
        self.say(f"check: activation {self.deployment.activation.drv_path} -> {self.deployment.activation.path}")
        for artifact in self.deployment.cached:
            self.say(f"check: cache-only {artifact.name} ({artifact.drv_path})")
        for artifact in self.deployment.local:
            self.say(f"check: reviewed-local {artifact.name} ({artifact.drv_path})")
        if self.deployment.migration:
            self.say(f"check: migration candidates={len(self.deployment.migration)}")

    def validate_omniwm_signature(self, runner: CommandRunner | None = None) -> None:
        """Verify the reviewed OmniWM wrapper before touching user state."""

        if self.deployment.system != "aarch64-darwin":
            return
        command_runner = runner or self.nix.runner
        candidates: list[Path] = []
        assert self.graph is not None
        omniwm_artifacts = [
            artifact
            for artifact in self.deployment.local
            if artifact.name.startswith("omniwm-")
        ]
        if not omniwm_artifacts:
            return
        for artifact in omniwm_artifacts:
            for _, output_path in selectors_for(artifact, self.graph):
                if output_path:
                    candidates.append(Path(output_path) / "Applications" / "OmniWM.app")
        candidates.extend(
            [
                Path(self.deployment.activation.path) / "home-path" / "Applications" / "OmniWM.app",
                Path(self.deployment.activation.path) / "Applications" / "OmniWM.app",
            ]
        )
        app = next((candidate for candidate in candidates if candidate.exists()), None)
        if app is None:
            raise RealizeHomeError(
                "OmniWM is listed as a local wrapper but its Applications/OmniWM.app "
                "output was not found after realization"
            )
        self.say(f"verifying OmniWM signature: {app}")
        try:
            command_runner.run(
                ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                check=True,
            )
        except (CommandError, RealizeHomeError) as exc:
            raise RealizeHomeError(f"OmniWM code signature verification failed: {exc}") from exc

    def run(self) -> str:
        version = self.nix.version()
        if version < MIN_NIX_VERSION:
            raise RealizeHomeError(
                "realize-home requires Nix >= 2.35.0 because older Nix versions "
                "can bypass the local-build guard with preferLocalBuild; "
                f"found {'.'.join(map(str, version))}"
            )
        self.prepare_graph()
        self.prepare_cached_output_graph()
        assert self.graph is not None
        for artifact in self.deployment.cached:
            self.realize_cached(artifact)
        for artifact in self.local_artifacts:
            self.realize_local(artifact)
        return self.deployment.activation.path


@dataclass(frozen=True)
class ProfileSnapshot:
    profile_path: Path | None
    profile_target: str | None
    profile_generation: int | None
    hm_links: tuple[tuple[Path, str], ...]


def _realpath_if_link(path: Path) -> str | None:
    try:
        if path.is_symlink() or path.exists():
            return os.path.realpath(path)
    except OSError:
        return None
    return None


def _profile_pointer(path: Path) -> tuple[Path, str | None, int | None] | None:
    """Resolve a bounded profile symlink chain to its mutable pointer.

    Older installs commonly have ``~/.nix-profile`` pointing at a per-user
    ``.../profile`` link, which in turn points at ``profile-N-link``.  Nix
    profile mutations should address that middle, mutable link directly.
    """

    current = path
    seen: set[Path] = set()
    last_link: Path | None = None
    for _ in range(16):
        try:
            if current in seen:
                if last_link is None:
                    return None
                return last_link, os.path.realpath(last_link), None
            if not current.is_symlink():
                if last_link is not None:
                    return last_link, os.path.realpath(last_link), None
                if current.exists():
                    return current, os.path.realpath(current), None
                return None
            seen.add(current)
            raw_target = os.readlink(current)
        except OSError:
            return None
        generation = _profile_generation(raw_target)
        target = Path(raw_target)
        if not target.is_absolute():
            target = current.parent / target
        if generation is not None:
            return current, os.path.realpath(current), generation
        last_link = current
        current = target
    if last_link is not None:
        return last_link, os.path.realpath(last_link), None
    return None


def _profile_generation(target: str | None) -> int | None:
    if not target:
        return None
    match = re.search(r"(?:^|/)(?:profile|home-manager)-(\d+)-link$", target)
    if match:
        return int(match.group(1))
    match = re.search(r"(?:^|/)profile-(\d+)$", target)
    return int(match.group(1)) if match else None


def profile_candidates(environ: Mapping[str, str] | None = None) -> tuple[Path, ...]:
    env = environ or os.environ
    home = Path(env.get("HOME", str(Path.home())))
    state_home = Path(env.get("XDG_STATE_HOME", str(home / ".local" / "state")))
    candidates: list[Path] = []
    if env.get("NIX_PROFILE"):
        candidates.append(Path(env["NIX_PROFILE"]))
    candidates.extend(
        [
            state_home / "nix" / "profiles" / "profile",
            home / ".nix-profile",
        ]
    )
    return tuple(dict.fromkeys(candidates))


def hm_generation_candidates(environ: Mapping[str, str] | None = None) -> tuple[Path, ...]:
    env = environ or os.environ
    home = Path(env.get("HOME", str(Path.home())))
    state_home = Path(env.get("XDG_STATE_HOME", str(home / ".local" / "state")))
    return (
        state_home / "home-manager" / "gcroots" / "current-home",
        state_home / "nix" / "profiles" / "home-manager",
        state_home / "home-manager" / "generation",
        state_home / "home-manager" / "profiles" / "home-manager",
    )


def snapshot_profiles(environ: Mapping[str, str] | None = None) -> ProfileSnapshot:
    profile_path: Path | None = None
    profile_target: str | None = None
    profile_generation: int | None = None
    for candidate in profile_candidates(environ):
        pointer = _profile_pointer(candidate)
        if pointer:
            profile_path, profile_target, profile_generation = pointer
            break

    hm_links: list[tuple[Path, str]] = []
    for candidate in hm_generation_candidates(environ):
        target = _realpath_if_link(candidate)
        if target:
            hm_links.append((candidate, target))
    return ProfileSnapshot(
        profile_path=profile_path,
        profile_target=profile_target,
        profile_generation=profile_generation,
        hm_links=tuple(hm_links),
    )


def _migration_specs(migration: Mapping[str, Any]) -> Mapping[str, Any]:
    manifest = migration.get("manifest")
    if isinstance(manifest, Mapping):
        return manifest
    return migration


def _urls_from_spec(spec: Mapping[str, Any]) -> tuple[str, ...]:
    values = spec.get("originalUrls", spec.get("originalUrl", ()))
    if isinstance(values, str):
        return (values,)
    if isinstance(values, list):
        return tuple(item for item in values if isinstance(item, str))
    return ()


def migration_removals(
    migration: Mapping[str, Any],
    entries: Sequence[Mapping[str, Any]],
    *,
    report: Any = sys.stdout,
) -> tuple[str, ...]:
    """Find profile entries matching explicit attrPath and original URL pairs.

    A missing entry is reported and ignored.  More than one exact match is a
    collision and aborts before any profile mutation can occur.
    """

    removals: list[str] = []
    collisions: list[str] = []
    removal_owners: dict[str, str] = {}
    specs = _migration_specs(migration)
    known_names = set(specs)
    for key, raw_spec in specs.items():
        if not isinstance(raw_spec, Mapping):
            print(f"migration left untouched (invalid manifest entry): {key}", file=report)
            continue
        attr_path = raw_spec.get("attrPath")
        urls = _urls_from_spec(raw_spec)
        if not isinstance(attr_path, str) or not attr_path or not urls:
            print(f"migration left untouched (incomplete manifest entry): {key}", file=report)
            continue
        matches: list[str] = []
        for entry in entries:
            entry_attr = entry.get("attrPath")
            entry_url = entry.get("originalUrl")
            entry_urls = entry.get("originalUrls")
            url_match = isinstance(entry_url, str) and entry_url in urls
            if isinstance(entry_urls, list):
                url_match = url_match or any(isinstance(item, str) and item in urls for item in entry_urls)
            # The manifest key is the profile element name.  Requiring all
            # three fields prevents an unrelated package with the same attrPath
            # and URL from being removed during migration.
            if entry.get("name") == key and entry_attr == attr_path and url_match:
                name = entry.get("name")
                if isinstance(name, str) and name:
                    matches.append(name)
        if len(matches) > 1:
            collisions.append(f"{key}: {', '.join(matches)}")
        elif len(matches) == 1:
            previous_owner = removal_owners.get(matches[0])
            if previous_owner is not None and previous_owner != key:
                collisions.append(f"{previous_owner} and {key}: {matches[0]}")
            else:
                removal_owners[matches[0]] = key
                removals.append(matches[0])
        else:
            print(f"migration left untouched (no exact match): {key}", file=report)
    for entry in entries:
        name = entry.get("name")
        if isinstance(name, str) and name and name not in known_names:
            print(f"migration left untouched (unmanaged profile entry): {name}", file=report)
    if collisions:
        raise RealizeHomeError(
            "profile migration collision; refusing all removals: " + "; ".join(collisions)
        )
    return tuple(dict.fromkeys(removals))


def _restore_hm_link(path: Path, target: str) -> None:
    """Restore one captured HM link atomically when it is safe to do so."""

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not path.is_symlink():
        raise OSError(f"refusing to replace non-symlink Home Manager path {path}")
    with tempfile.NamedTemporaryFile(prefix=f".{path.name}.restore-", dir=path.parent, delete=True) as temp:
        temporary = Path(temp.name)
    temporary.unlink(missing_ok=True)
    os.symlink(target, temporary)
    os.replace(temporary, path)


def _activate_path(path: str, runner: CommandRunner) -> subprocess.CompletedProcess[str]:
    activate = str(Path(path) / "activate")
    # Use Home Manager's default driver so it records the generation and runs
    # its normal migration hooks.  The surrounding code snapshots the profile
    # before invoking this command and can restore it exactly on failure.
    return runner.run([activate], check=True)


def activate_with_rollback(
    deployment: Deployment,
    nix: Nix,
    activation_path: str,
    snapshot: ProfileSnapshot,
    *,
    before_activate_script: str | None = None,
    runner: CommandRunner | None = None,
    output: Any = sys.stdout,
) -> None:
    """Activate and, on failure, restore HM first and Nix profile second.

    The optional guard is deliberately run inside this transaction.  The
    caller also runs it before profile migration, but that early check cannot
    cover edits made while migration is in progress.  A failure here therefore
    follows the same rollback path as a failed activation and leaves no stale
    candidate activation running.
    """

    command_runner = runner or nix.runner
    activation_failure: Exception
    try:
        if before_activate_script:
            run_before_activate_hook(
                before_activate_script,
                command_runner,
                output=output,
            )
        _activate_path(activation_path, command_runner)
        print("activation complete", file=output)
        return
    except (CommandError, RealizeHomeError) as activation_error:
        activation_failure = activation_error
        print(f"activation failed: {activation_error}", file=output)

    hm_error: Exception | None = None
    if snapshot.hm_links:
        old_target = snapshot.hm_links[0][1]
        try:
            _activate_path(old_target, command_runner)
            print("old Home Manager generation activated", file=output)
        except Exception as exc:  # rollback must continue to profile restoration
            hm_error = exc
            print(f"old Home Manager activation failed: {exc}", file=output)
            for path, target in snapshot.hm_links:
                try:
                    _restore_hm_link(path, target)
                except OSError as restore_error:
                    print(f"could not restore Home Manager link {path}: {restore_error}", file=output)
    else:
        print("no old Home Manager generation link was found", file=output)

    rollback_error: Exception | None = None
    if snapshot.profile_generation is not None:
        try:
            # Keep this as the final external rollback command.  It restores
            # the exact captured generation rather than guessing a profile name.
            if snapshot.profile_path is None:
                raise RealizeHomeError(
                    "no default Nix profile path was captured; refusing an implicit rollback"
                )
            nix.profile_rollback(snapshot.profile_generation, snapshot.profile_path)
            print(
                f"Nix profile rolled back to generation {snapshot.profile_generation}",
                file=output,
            )
        except Exception as exc:
            rollback_error = exc
            print(f"Nix profile rollback failed: {exc}", file=output)
    else:
        print("no numeric Nix profile generation was captured", file=output)

    details = ["activation failed and rollback was attempted"]
    if hm_error:
        details.append(f"old Home Manager activation error: {hm_error}")
    if rollback_error:
        details.append(f"profile rollback error: {rollback_error}")
    raise RealizeHomeError("; ".join(details)) from activation_failure


def resolve_bash(environ: Mapping[str, str] | None = None) -> str:
    """Resolve the shell for a preactivation guard from the caller's PATH."""

    env = environ if environ is not None else os.environ
    bash = shutil.which("bash", path=env.get("PATH", ""))
    if not bash:
        raise RealizeHomeError(
            "before-activate guard requires an executable bash on PATH"
        )
    return os.path.abspath(bash)


def run_before_activate_hook(
    script: str,
    runner: CommandRunner,
    *,
    output: Any = sys.stdout,
    environ: Mapping[str, str] | None = None,
) -> None:
    """Run the caller-supplied source snapshot check immediately preactivation."""

    if not script:
        raise RealizeHomeError("before-activate guard path is empty")
    print(f"running before-activate guard: {script}", file=output)
    try:
        runner.run([resolve_bash(environ), script], check=True)
    except (CommandError, RealizeHomeError) as exc:
        raise RealizeHomeError(
            "before-activate guard failed; refusing profile migration and activation\n"
            f"{exc}"
        ) from exc


def migrate_profile(
    deployment: Deployment,
    nix: Nix,
    snapshot: ProfileSnapshot,
    *,
    output: Any = sys.stdout,
) -> tuple[str, ...]:
    if not deployment.migration:
        return ()
    if snapshot.profile_path is None:
        print(
            "profile migration skipped: no default Nix profile exists yet",
            file=output,
        )
        return ()
    if snapshot.profile_generation is None:
        raise RealizeHomeError(
            "default Nix profile exists but has no captured numeric generation; "
            "refusing profile migration without an exact rollback target"
        )
    entries = nix.profile_list(snapshot.profile_path)
    removals = migration_removals(deployment.migration, entries, report=output)
    if removals:
        nix.profile_remove(removals, snapshot.profile_path)
        print(f"removed managed profile entries: {', '.join(removals)}", file=output)
    return removals


def load_deployment(nix: Nix, flake: str, host: str) -> Deployment:
    return parse_deployment(nix.eval_deployment(flake, host))


def current_system() -> str:
    machine = platform.machine().lower()
    if sys.platform == "darwin":
        arch = "aarch64" if machine in {"arm64", "aarch64"} else machine
        return f"{arch}-darwin"
    if sys.platform.startswith("linux"):
        arch = "aarch64" if machine in {"arm64", "aarch64"} else machine
        return f"{arch}-linux"
    return f"{machine}-{sys.platform}"


def verify_deployment_host(deployment: Deployment, environ: Mapping[str, str] | None = None) -> None:
    """Check manifest host identity before any profile mutation or activation."""

    env = environ or os.environ
    expected_system = current_system()
    if deployment.system != expected_system:
        raise RealizeHomeError(
            f"deployment system {deployment.system!r} does not match this host {expected_system!r}"
        )
    home = env.get("HOME")
    if not home:
        raise RealizeHomeError("HOME is unset; refusing profile migration or activation")
    if os.path.abspath(deployment.home_directory) != os.path.abspath(home):
        raise RealizeHomeError(
            f"deployment homeDirectory {deployment.home_directory!r} does not match HOME {home!r}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="realize-home",
        description="Realize reviewed Home Manager deployment outputs safely.",
    )
    parser.add_argument("--flake", required=True, help="flake path or reference")
    parser.add_argument("--host", required=True, help="deployment host attribute")
    parser.add_argument("--check", action="store_true", help="evaluate and print a plan only")
    parser.add_argument(
        "--before-activate",
        metavar="SCRIPT",
        help="run bash SCRIPT after realization as a preactivation source guard",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    nix: Nix | None = None,
    output: Any = sys.stdout,
) -> int:
    args = build_parser().parse_args(argv)
    nix_client = nix or Nix()
    try:
        deployment = load_deployment(nix_client, args.flake, args.host)
        realizer = Realizer(deployment=deployment, nix=nix_client, output=output)
        if args.check:
            # Deliberately stop before version checks, graph queries, cache
            # fetches, profile reads/removals, or activation.
            realizer.plan()
            return 0

        verify_deployment_host(deployment)
        gc_root_dir = Path(tempfile.mkdtemp(prefix="realize-home-gcroots-"))
        previous_gc_root_dir = nix_client.gc_root_dir
        nix_client.gc_root_dir = gc_root_dir
        try:
            activation_path = realizer.run()
            realizer.validate_omniwm_signature()
            if args.before_activate:
                # This early check prevents profile reads or removals when the
                # source is already stale before migration starts.  The same
                # guard is run again inside the rollback transaction below to
                # cover edits made during migration.
                run_before_activate_hook(
                    args.before_activate,
                    nix_client.runner,
                    output=output,
                )
            snapshot = snapshot_profiles()
            migrate_profile(deployment, nix_client, snapshot, output=output)
            activate_with_rollback(
                deployment,
                nix_client,
                activation_path,
                snapshot,
                before_activate_script=args.before_activate,
                output=output,
            )
            return 0
        finally:
            # Keep roots alive through activation and any rollback commands.
            # Once that transaction has finished, removing the private
            # directory releases all temporary out-links.
            nix_client.gc_root_dir = previous_gc_root_dir
            shutil.rmtree(gc_root_dir, ignore_errors=True)
    except (RealizeHomeError, CommandError) as exc:
        print(f"realize-home: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
