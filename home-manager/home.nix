{ config, lib, pkgs, homeDir, ... }:

let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
in
{
  # username is uniform; homeDirectory differs per platform and is supplied
  # per-configuration as a module arg (homeDir) from flake.nix extraArgs.
  home.username = "kayg";
  home.homeDirectory = homeDir;

  # Packages for BOTH macOS and Linux hosts.
  home.packages = with pkgs;
    [
      # shell / prompt / history
      oh-my-posh
      zoxide
      atuin
      zellij

      # file / text tools
      bat
      eza
      fd
      ripgrep
      fzf
      jq
      yq
      delta

      # dev tooling
      git
      gh
      nodejs_22
      bun
      python3
      pipx

      # media / misc
      ffmpeg

      # ghostty terminfo (no UI needed here; just the terminfo so
      # xterm-ghostty TERM works over ssh from ghostty terminals). The attr
      # source differs by platform: linux builds ghostty from source
      # (pkgs.ghostty), darwin uses the official dmg wrapper
      # (pkgs.ghostty-bin) — pkgs.ghostty refuses to evaluate on darwin
      # (meta.platforms = linux only).
    ]
    ++ [ (if isDarwin then pkgs.ghostty-bin.terminfo else pkgs.ghostty.terminfo) ]
    # console-only emacs on every platform: the terminal is the interface.
    # emacs-nox exists on both linux and darwin in nixpkgs-unstable.
    ++ [ pkgs.emacs-nox ]
    # oh-my-pi (binary: omp) — terminal coding agent from numtide's
    # llm-agents.nix, exposed as `omp` by the per-platform overlays.
    ++ [ pkgs.omp ];

  # OmniWM tiling window manager — macOS only (headless Linux hosts skip it).
  programs.omniwm = {
    enable = isDarwin;
    launchd.enable = isDarwin;
    launchd.keepAlive = false;
  };

  # zsh is NOT managed here. The dotfiles repo owns ~/.zshenv and
  # ~/.config/zsh/.zshrc via symlinks (scripts/dot setup zsh), including its
  # own plugin sources. Letting home-manager's programs.zsh write into the
  # same paths collides at activation ("would be clobbered") and would fork
  # the config. Packages that zsh needs are in home.packages above.

  # git identity + sensible defaults
  programs.git = {
    enable = true;
    settings = {
      user.name = "kayg";
      user.email = "mail@kayg.org";
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };
  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  # bat as the pager
  programs.bat.enable = true;

  # eza as ls replacement
  programs.eza.enable = true;

  home.stateVersion = "24.11";
}