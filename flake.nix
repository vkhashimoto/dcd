{
  description = "A Dynamic Change Directory (dcd)";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        dcd = pkgs.stdenv.mkDerivation {
          pname = "dcd";
          version = "0.1.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.zig ];
          dontConfigure = true;
          buildPhase = ''
            zig build install \
              --prefix $out \
              -Doptimize=ReleaseSafe \
              --global-cache-dir $(mktemp -d)
          '';
          dontInstall = true;
        };
      in
      {
        packages.default = dcd;

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.nixfmt
            pkgs.zig
            pkgs.zls
          ];
        };
      }
    );
}
