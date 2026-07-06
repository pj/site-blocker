{
  description = "site_blocker — rules-based content blocker for macOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      # Dev shell only. The pure Swift package (RulesEngine) builds/tests with the Xcode
      # toolchain via `swift test`; the signed .app + system extension are built with xcodebuild.
      # Nix can't hermetically build/sign macOS system extensions (no Apple SDK in nixpkgs, and
      # codesigning needs keychain access the sandbox blocks), so its role here is tooling + env.
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pkgs.just # task runner — `just` to list recipes
          pkgs.xcodegen # generate the .xcodeproj from mac/project.yml
          pkgs.swiftformat # swiftformat .
          pkgs.xcbeautify # xcodebuild ... | xcbeautify
          pkgs.jujutsu # jj
        ];

        shellHook = ''
          echo "site_blocker dev shell"
          echo "  Swift toolchain: from Xcode (xcrun), not nix"
          echo "  Engine tests:    (cd RulesEngine && swift test)"
          echo "  Generate proj:   xcodegen generate --spec mac/project.yml"
        '';
      };
    };
}
