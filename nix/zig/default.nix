{stdenv}: let
  throwSystem = throw "Unsupported system: ${stdenv.hostPlatform.system}";

  urlArch =
    {
      x86_64-linux = "linux-x86_64";
      aarch64-linux = "linux-aarch64";
      x86_64-darwin = "macos-x86";
      aarch64-darwin = "macos-aarch64";
    }
    .${stdenv.hostPlatform.system}
    or throwSystem;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "zig";
    version = "0.13.0-dev.351+64ef45eb0";
    src = fetchTarball {
      url = "https://pkg.machengine.org/zig/zig-${urlArch}-${finalAttrs.version}.tar.xz";
      sha256 = "sha256:033q435y14v50lp80yxi3llkvzryq6ldgzjcq39dlgisppq5zi9c";
    };
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;
    installPhase = ''
      mkdir -p $out/{doc,bin,lib}
      [ -d docs ] && cp -r docs/* $out/doc
      [ -d doc ] && cp -r doc/* $out/doc
      cp -r lib/* $out/lib
      cp zig $out/bin/zig
    '';
  })
