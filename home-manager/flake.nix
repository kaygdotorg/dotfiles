{
  description = "kayg home-manager configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/07e1d92cdc0ed416cfa11ff3ca40d17e61cfba7a";
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
