{ config, pkgs, ... }:

{
  home.username = "kayg";
  home.homeDirectory = "/Users/kayg";

  # Packages referenced by the dotfiles zshrc + the real user tools on mbp.
  home.packages = with pkgs; [
    # shell / prompt / history
    oh-my-posh
    zoxide
    atuin
    zellij
    tmux

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

    # misc user tools present on mbp
    ffmpeg
    emacs
    cliclick

    # ghostty terminfo (no UI needed on headless hosts; just the terminfo
    # so xterm-ghostty TERM works over ssh from ghostty terminals)
    pkgs.ghostty.terminfo
  ];

  # zsh as the shell, with the dotfiles config wired in
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    # ZDOTDIR is set by the dotfiles .zshenv; home-manager should not clobber it
    dotDir = "${config.home.homeDirectory}/.config/zsh";
  };

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
