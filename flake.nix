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

          pkgs.wgpu-native

          pkgs.libGL
          pkgs.libxkbcommon
          pkgs.vulkan-loader
          pkgs.vulkan-validation-layers
          pkgs.wayland
          pkgs.xorg.libX11
          pkgs.xorg.libXcursor
          pkgs.xorg.libxcb
          pkgs.xorg.libXi
          pkgs.xorg.libXrandr
        ];
      in rec {
        formatter = pkgs.alejandra;

        packages.zig = pkgs.callPackage ./nix/zig/default.nix {};

        devShells.default = pkgs.mkShell {
          buildInputs =
            [
              packages.zig

              (pkgs.zls.overrideAttrs (oldAttrs: {
                version = "d2d5f43017e54e036df3c9cac365541ea5cabce9";
                src = oldAttrs.src.override {
                  hash = "sha256-qL9T/dgQLGgSk5vA+1ne3LSWIk3b+tGiNuAXPf2VexU=";
                };
              }))
            ]
            ++ libs;

          env.NIX = 1;
          env.VULKAN_SDK = "${pkgs.vulkan-headers}";
          env.VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";

          env.LD_LIBRARY_PATH = lib.makeLibraryPath libs;
        };
      };
    };
}
