{ config, lib, pkgs, ... }:
let
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  updater = "${config.home.homeDirectory}/.local/bin/dotfiles-nix-update";
  logDir = "${config.xdg.stateHome}/dotfiles";
  linuxUpdaterPath = lib.makeBinPath [
    pkgs.coreutils
    pkgs.git
    pkgs.findutils
    pkgs.diffutils
    pkgs.gawk
    pkgs.gnused
    pkgs.gnugrep
    pkgs.procps
    pkgs.bash
    pkgs.util-linux
    pkgs.hostname
    pkgs.python3
  ];
in {
  home.activation.dotfilesUpdateLogs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run mkdir -p ${lib.escapeShellArg logDir}
  '';

  launchd.agents.dotfiles-nix-update = lib.mkIf isDarwin {
    enable = true;
    config = {
      # Keep this plist stable when nixpkgs changes: reloading the job
      # during its own activation would terminate the running update.
      ProgramArguments = [ "/bin/bash" updater ];
      EnvironmentVariables.PATH = "${config.home.homeDirectory}/.nix-profile/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      StartCalendarInterval = [ { Hour = 9; Minute = 17; } ];
      StandardOutPath = "${logDir}/nix-update.log";
      StandardErrorPath = "${logDir}/nix-update.err";
    };
  };

  systemd.user.services.dotfiles-nix-update = lib.mkIf (!isDarwin) {
    Unit = {
      Description = "Update the dotfiles Home Manager configuration";
      # Activation must finish before a newly generated service is used.
      X-SwitchMethod = "keep-old";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.bash}/bin/bash ${updater}";
      Environment = [ "PATH=${linuxUpdaterPath}:/nix/var/nix/profiles/default/bin:/usr/bin:/bin" ];
      TimeoutStartSec = "1h";
    };
  };
  systemd.user.timers.dotfiles-nix-update = lib.mkIf (!isDarwin) {
    Unit.Description = "Daily dotfiles package update";
    Timer = {
      OnCalendar = "*-*-* 03:47:00 UTC";
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
  systemd.user.startServices = lib.mkIf (!isDarwin) "sd-switch";
}
