{
  lib,
  fetchurl,
  libarchive,
  stdenvNoCC,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "omniwm";
  version = "0.6.10";

  src = fetchurl {
    url = "https://github.com/BarutSRB/OmniWM/releases/download/v${finalAttrs.version}/OmniWM-v${finalAttrs.version}.zip";
    hash = "sha256-EO74kwd9IQ0VRfV3WiuSsvNm32HbT72KvCKzqx0IxK8=";
  };

  dontUnpack = true;

  # OmniWM is a precompiled, Developer ID signed app bundle. Generic Nix
  # fixups can rewrite Mach-O files or strip their code, invalidating the
  # upstream signature and the bundle's sealed resource structure.
  dontBuild = true;
  dontFixup = true;
  dontStrip = true;

  strictDeps = true;

  nativeBuildInputs = [ libarchive ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/Applications/
    bsdtar -xf $src -C $out/Applications/

    mkdir -p $out/bin
    ln -s $out/Applications/OmniWM.app/Contents/MacOS/OmniWM $out/bin/OmniWM
    ln -s $out/Applications/OmniWM.app/Contents/MacOS/omniwmctl $out/bin/omniwmctl

    runHook postInstall
  '';

  doInstallCheck = true;

  # codesign is a host-only Apple tool and is intentionally not a Nix build
  # input. The Darwin realization helper verifies the signed app with the
  # host's /usr/bin/codesign before activation; this check covers structure.
  installCheckPhase = ''
    runHook preInstallCheck

    test -d "$out/Applications/OmniWM.app"
    test -d "$out/Applications/OmniWM.app/Contents/MacOS"
    test -x "$out/Applications/OmniWM.app/Contents/MacOS/OmniWM"
    test -x "$out/Applications/OmniWM.app/Contents/MacOS/omniwmctl"
    test -L "$out/bin/OmniWM"
    test -L "$out/bin/omniwmctl"

    runHook postInstallCheck
  '';

  meta = {
    description = "macOS tiling window manager inspired by Niri and Hyprland";
    homepage = "https://github.com/BarutSRB/OmniWM";
    license = lib.licenses.gpl2Only;
    mainProgram = "OmniWM";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
