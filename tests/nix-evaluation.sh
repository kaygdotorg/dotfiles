#!/usr/bin/env bash
# Read-only Nix evaluation checks; no package builds or activation.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
nix flake check --all-systems --no-build --no-write-lock-file \
    --option allow-import-from-derivation false "path:${repo_dir}/home-manager"
python3 - "${repo_dir}" <<'PYTHON'
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

repo = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("realize_home", repo / "nix/realize_home.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
flake = f"path:{repo}/home-manager"

def evaluate(attr):
    return json.loads(subprocess.check_output([
        "nix", "eval", "--json", "--no-write-lock-file",
        "--option", "allow-import-from-derivation", "false", f"{flake}#{attr}",
    ], text=True))

for host in ("kayg", "kayg-mba", "kayg-linux", "kayg-linux-arm"):
    deployment = module.parse_deployment(evaluate(f"deployment.{host}"))
    if deployment.system.endswith("-linux"):
        method = evaluate(f"homeConfigurations.{host}.config.systemd.user.services.dotfiles-nix-update.Unit.X-SwitchMethod")
        assert method == "keep-old", "activation would terminate its own Linux updater"
        environment = evaluate(
            f"homeConfigurations.{host}.config.systemd.user.services.dotfiles-nix-update.Service.Environment"
        )
        path_entries = [
            value.split("=", 1)[1]
            for value in environment
            if isinstance(value, str) and value.startswith("PATH=")
        ]
        assert len(path_entries) == 1, "Linux updater must define one explicit PATH"
        updater_path = path_entries[0]
        for package_name in (
            "coreutils",
            "git",
            "findutils",
            "diffutils",
            "gawk",
            "gnused",
            "gnugrep",
            "procps",
            "bash",
            "util-linux",
            "hostname",
            "python3",
        ):
            assert f"-{package_name}-" in updater_path, (
                f"Linux updater PATH is missing the precompiled {package_name} utility"
            )
    else:
        plist = next(item for item in deployment.local if item.name == "org.nix-community.home.dotfiles-nix-update.plist")
        raw = json.loads(subprocess.check_output(["nix", "derivation", "show", plist.drv_path], text=True))
        # writeText content is carried in env.text in the Nix derivation JSON.
        data = next(iter(raw.get("derivations", raw).values()))
        text = data.get("env", {}).get("text") or data.get("structuredAttrs", {}).get("text")
        assert isinstance(text, str) and "/bin/bash" in text
        assert not re.search(r"/nix/store/[a-z0-9]{32}-", text), "package updates would reload their own launchd job"
    print(f"PASS {host}: deployment schema and updater lifecycle")
PYTHON
