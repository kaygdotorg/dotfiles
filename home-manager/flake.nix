{
  description = "kayg home-manager configuration (macOS + Linux)";

  inputs = {
    # track the unstable BRANCH (not a frozen rev): nix flake update moves
    # this daily via the auto-update job. flake.lock pins whatever HEAD was
    # at last update — the lock is the reproducibility, the branch is the
    # freshness.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # terminal coding agent (binary: omp). consumed as llmAgents.packages.omp
    # through the llm-agents overlay below.
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Apple's official font DMGs (SF Pro/Mono/Compact/…, NY). Used on the
    # darwin hosts to register all faces for app font pickers; the -nerd
    # variants from this flake are deliberately NOT installed (local patch
    # pass, see home.nix). Darwin-only: the Apple EULA limits these fonts
    # to Apple operating systems.
    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, llm-agents, apple-fonts, ... }: {
    # one entry per host platform; the module set is shared. homeDir is
    # injected so home.nix can set home.homeDirectory per platform without
    # duplicating the package list.
    homeConfigurations = {
      # macOS — Apple Silicon. homeDir reaches home.nix through
      # extraSpecialArgs (the homeManagerConfiguration arg name).
      # mbp runs the daily launchd HM switch with this entry; omp is cached
      # here so switches stay fetch-only.
      kayg = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        extraSpecialArgs = {
          homeDir = "/Users/kayg";
          withOmp = true;
          appleFonts = apple-fonts.packages.aarch64-darwin;
        };
        modules = [
          ./home.nix
          {
            nixpkgs.overlays = [
              (final: prev: {
                omniwm = final.callPackage ./omniwm/package.nix { };
                omp = llm-agents.packages.${prev.stdenv.hostPlatform.system}.omp;
              })
            ];
          }
          # omniwm module: vendored module removed — home-manager master now
          # ships upstream modules/programs/omniwm.nix with the same option
          # shape (enable/package/launchd.keepAlive), so importing ours
          # collides with a duplicate-option assertion.
        ];
      };

      # macOS — Apple Silicon, mba host. Same user/dir as `kayg` but omp is
      # excluded: this host has no binary-cache coverage for it, and omp is
      # a from-source build (rust + bun) that must never run unattended.
      # Switch with: nix run home-manager/master -- switch --flake .#kayg-mba
      kayg-mba = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        extraSpecialArgs = {
          homeDir = "/Users/kayg";
          withOmp = false;
          appleFonts = apple-fonts.packages.aarch64-darwin;
        };
        modules = [
          ./home.nix
          {
            nixpkgs.overlays = [
              (final: prev: {
                omniwm = final.callPackage ./omniwm/package.nix { };
                omp = llm-agents.packages.${prev.stdenv.hostPlatform.system}.omp;
              })
            ];
          }
        ];
      };

      # Linux — x86_64 (agents VMs)
      kayg-linux = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = { homeDir = "/home/kayg"; withOmp = false; };
        modules = [
          ./home.nix
          {
            nixpkgs.overlays = [
              (final: prev: {
                omp = llm-agents.packages.${prev.stdenv.hostPlatform.system}.omp;
              })
            ];
          }
        ];
      };

      # Linux — aarch64 (o2-style arm hosts)
      kayg-linux-arm = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.aarch64-linux;
        extraSpecialArgs = { homeDir = "/home/kayg"; withOmp = false; };
        modules = [
          ./home.nix
          {
            nixpkgs.overlays = [
              (final: prev: {
                omp = llm-agents.packages.${prev.stdenv.hostPlatform.system}.omp;
              })
            ];
          }
        ];
      };
    };
  };
}