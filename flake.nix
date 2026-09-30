{
  description = "mwmbar dev shell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.swift-format
          pkgs.swiftlint
          pkgs.gnumake
        ];
        shellHook = ''
          # swiftlint's SourceKitten dlopens sourcekitdInProc.framework from a
          # real Apple toolchain; nix's swiftlint doesn't bundle one, and
          # mkShell's DEVELOPER_DIR points at a nix apple-sdk. Find it in the
          # selected Xcode, any installed Xcode, or Command Line Tools.
          for dir in \
            "$(/usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null)/Toolchains/XcodeDefault.xctoolchain" \
            /Applications/Xcode*.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain \
            /Library/Developer/CommandLineTools
          do
            if [ -e "$dir/usr/lib/sourcekitdInProc.framework" ]; then
              export TOOLCHAIN_DIR="$dir"
              break
            fi
          done
          [ -n "$TOOLCHAIN_DIR" ] || echo "warning: no sourcekitdInProc.framework found; swiftlint will crash" >&2
        '';
      };
    };
}
