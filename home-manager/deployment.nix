# Exact derivation identities accepted by nix/realize-home. Everything else
# must already exist or be downloadable; package names are not a build permit.
{ lib, home, wrappers }:
let
  config = home.config;
  pkgs = home.pkgs;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  system = home.pkgs.stdenv.hostPlatform.system;
  describe = p: {
    inherit (p) name drvPath;
    outputs = map (output: p.${output}.outPath) (if p.outputSpecified or false then [ p.outputName ] else (p.meta.outputsToInstall or [ p.outputName ]));
  };
  # These strings are produced by the reviewed Home Manager file/activation
  # modules. Their contexts identify text generators and link farms directly.
  contexts = map builtins.getContext (
    [
      config.home.activationPackage.buildCommand
      config.lib.bash.initHomeManagerLib
      config.home-files.buildCommand
      config.home.activation.checkLinkTargets.data
      config.home.activation.linkGeneration.data
    ] ++ map (file: toString file.source) (builtins.attrValues config.home.file)
  );
  contextDrvs = lib.unique (lib.concatMap builtins.attrNames contexts);
  # Home Manager keeps these intermediate text derivations in module-local
  # lets. Reproduce the exact reviewed writers so changes upstream fail closed
  # rather than granting a build permit to every child of the activation graph.
  agentFiles = lib.concatMap (agent:
    let
      cnf = agent.config;
      args = lib.optional (cnf.Program != null) cnf.Program
        ++ lib.optionals (cnf.ProgramArguments != null) cnf.ProgramArguments;
      plist = (removeAttrs cnf [ "Program" "ProgramArguments" ]) // {
        ProgramArguments = [ "/bin/sh" "-c"
          "/bin/wait4path /nix/store && exec ${lib.escapeShellArgs args}" ];
      };
    in assert lib.assertMsg agent.waitForNixStore
      "Review the launchd launcher before enabling a new local generator"; [
      (pkgs.writeText "${cnf.Label}.plist" (lib.generators.toPlist { escape = true; } plist))
      (pkgs.writeText "${cnf.Label}.domain" "${agent.domain}\n")
    ]
  ) (lib.filter (agent: agent.enable) (builtins.attrValues config.launchd.agents));
  fontLinks = pkgs.buildEnv {
    name = "home-manager-fonts";
    paths = config.home.packages;
    pathsToLink = [ "/share/fonts" ];
  };
  # The Linux MIME module creates two empty directories so buildEnv merges
  # real directories rather than symlinking them. These only run mkdir.
  mimeDirs = lib.optionals config.xdg.mime.enable (map (index:
    pkgs.runCommandLocal "dummy-xdg-mime-dirs${toString index}" { } ''
      mkdir -p $out/share/{applications,mime/packages}
    ''
  ) [ 1 2 ]);
  generated = [
    config.home.activationPackage
    config.home.path
    config.home.sessionVariablesPackage
    config.home-files
    config.home.internal.filePutterConfig
  ] ++ mimeDirs ++ lib.optionals isDarwin ([ fontLinks ] ++ agentFiles);
  # OmniWM downloads an already compiled ZIP through a fixed-output fetcher.
  downloads = lib.concatMap (p: lib.optional (lib.isDerivation (p.src or null)) p.src) wrappers;
  localPackages = generated ++ wrappers ++ downloads;
  localIds = map (p: p.drvPath) localPackages ++ contextDrvs;
  migratedNixpkgs = {
    Normal-NF = "maple-mono.Normal-NF";
    # Retire legacy standalone installs; Caddy is no longer a managed package.
    caddy = "caddy";
    cascadia-code = "cascadia-code";
    coreutils = "coreutils";
    fastfetch = "fastfetch";
    forgejo-cli = "forgejo-cli";
    gitleaks = "gitleaks";
    home-assistant-cli = "home-assistant-cli";
    mosh = "mosh";
    rtk = "rtk";
    rustup = "rustup";
    spicetify-cli = "spicetify-cli";
    uv = "uv";
    wasm-pack = "wasm-pack";
    wget = "wget";
  };
in
assert lib.assertMsg (config.home.fileActivator == "legacy")
  "Review the file activation generators before changing activators";
assert lib.assertMsg (builtins.all (p:
  if (p.pname or "") == "omniwm" then (p.dontBuild or false)
  else (p.buildPhase or "not-reviewed") == ""
) wrappers) "Local wrappers must only unpack precompiled apps or unmodified fonts";
{
  inherit system;
  homeDirectory = config.home.homeDirectory;
  activation = {
    inherit (config.home.activationPackage) drvPath;
    path = config.home.activationPackage.outPath;
  };
  cached = map describe (lib.filter (p: !(builtins.elem p.drvPath localIds)) config.home.packages);
  local = map describe localPackages ++ map (drvPath: {
    inherit drvPath;
    name = builtins.baseNameOf drvPath;
    outputs = [ ];
  }) (lib.filter (path: lib.hasSuffix ".drv" path && !(builtins.elem path (map (p: p.drvPath) localPackages))) contextDrvs);
  migration = lib.mapAttrs (_: attr: {
    attrPath = "legacyPackages.${system}.${attr}";
    originalUrls = [ "github:NixOS/nixpkgs/nixpkgs-unstable" "flake:nixpkgs" ];
  }) migratedNixpkgs // lib.genAttrs [ "claude-code" "cli-proxy-api" ] (name: {
    attrPath = "packages.${system}.${name}";
    originalUrls = [ "github:numtide/llm-agents.nix" ];
  });
}
