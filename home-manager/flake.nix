{
  description = "kayg home-manager configuration";

  inputs = {
    # track the unstable BRANCH (not a frozen rev): nix flake update moves
    # this daily via the auto-update LaunchAgent. flake.lock pins whatever
    # HEAD was at last update — the lock is the reproducibility, the branch
    # is the freshness.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs: {
    homeConfigurations = {
      kayg = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.aarch64-darwin;
        modules = [
          ./home.nix
          {
            nixpkgs.overlays = [
              (final: prev: {
                omniwm = final.callPackage ./omniwm/package.nix { };
              })
            ];
          }
          ./omniwm/module.nix
        ];
      };
    };
  };
}
