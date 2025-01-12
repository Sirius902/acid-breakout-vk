{
  description = "acid-breakout-vk flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = {flake-parts, ...} @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = {pkgs, ...}: let
        inherit (pkgs) lib;
        libs = [
          pkgs.glfw3
          pkgs.openal

          pkgs.glslang
          pkgs.vulkan-headers

          pkgs.libGL
          pkgs.libxkbcommon
          pkgs.vulkan-loader
          pkgs.wayland
          pkgs.xorg.libX11
          pkgs.xorg.libXcursor
          pkgs.xorg.libxcb
          pkgs.xorg.libXi
        ];
      in rec {
        formatter = pkgs.alejandra;

        packages.zig = pkgs.callPackage ./nix/zig/default.nix {};

        devShells.default = pkgs.mkShell {
          buildInputs =
            [
              packages.zig
            ]
            ++ libs;

          env.VULKAN_SDK = "${pkgs.vulkan-headers}";

          env.LD_LIBRARY_PATH = lib.makeLibraryPath libs;
        };
      };
    };
}
