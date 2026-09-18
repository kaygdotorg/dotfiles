{
  description = "kayg Home Manager configuration for macOS and Linux";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Preserve Numtide's own dependency pins to match its binary cache.
    llm-agents.url = "github:numtide/llm-agents.nix";
    apple-fonts = {
      url = "github:Lyndeno/apple-fonts.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, llm-agents, apple-fonts, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
      forSystems = lib.genAttrs systems;
      omniwm = nixpkgs.legacyPackages.aarch64-darwin.callPackage ./omniwm/package.nix { };
      # 1Password CLI (`op`) is unfree. Allow exactly this one package instead
      # of turning on allowUnfree for the whole package set. Agents use `op`
      # with a service-account token to read and save secrets, so it must
      # exist on every host. Unfree outputs are not on cache.nixos.org, so
      # deployment.nix lists it as a reviewed local repackage (it only unpacks
      # the vendor's signed binary).
      onePasswordCliFor = system: (import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = p: lib.getName p == "1password-cli";
      })._1password-cli;
      mkHome = system: homeDir:
        let pkgs = nixpkgs.legacyPackages.${system};
        in home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          extraSpecialArgs = {
            inherit homeDir;
            llmPackages = llm-agents.packages.${system};
            onePasswordCli = onePasswordCliFor system;
            appleFonts = if pkgs.stdenv.hostPlatform.isDarwin then apple-fonts.packages.${system} else null;
          };
          modules = [
            ./home.nix
            ./updates.nix
            (lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
              programs.omniwm.package = omniwm;
            })
          ];
        };
      hosts = {
        kayg = mkHome "aarch64-darwin" "/Users/kayg";
        kayg-mba = mkHome "aarch64-darwin" "/Users/kayg";
        kayg-linux = mkHome "x86_64-linux" "/home/kayg";
        kayg-linux-arm = mkHome "aarch64-linux" "/home/kayg";
      };
    in {
      homeConfigurations = hosts;
      packages = forSystems (system: {
        # Tools are from the same lock as the home configuration.
        nix-update = nixpkgs.legacyPackages.${system}.nix-update;
        python3 = nixpkgs.legacyPackages.${system}.python3;
        home-manager = home-manager.packages.${system}.home-manager;
      } // lib.optionalAttrs (system == "aarch64-darwin") { inherit omniwm; });
      deployment = lib.mapAttrs (_: home:
        let system = home.pkgs.stdenv.hostPlatform.system;
        in import ./deployment.nix {
          inherit lib home;
          vendorBinaries = [ (onePasswordCliFor system) ];
          wrappers = lib.optionals (system == "aarch64-darwin") (
            [ omniwm ] ++ (with apple-fonts.packages.${system}; [
              sf-pro sf-compact sf-mono sf-arabic sf-armenian sf-georgian sf-hebrew ny
            ])
          );
        }) hosts;
    };
}
