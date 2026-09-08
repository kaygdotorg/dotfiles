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
  };

  outputs = { self, nixpkgs, home-manager, llm-agents, ... }: {
    # one entry per host platform; the module set is shared. homeDir is
    # injected so home.nix can set home.homeDirectory per platform without
    # duplicating the package list.
    homeConfigurations = {
      # macOS — Apple Silicon. homeDir reaches home.nix through
      # extraSpecialArgs (the homeManagerConfiguration arg name).
      kayg = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        extraSpecialArgs = { homeDir = "/Users/kayg"; };
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

      # Linux — x86_64 (agents VMs)
      kayg-linux = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = { homeDir = "/home/kayg"; };
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
        extraSpecialArgs = { homeDir = "/home/kayg"; };
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