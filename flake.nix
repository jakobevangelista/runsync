{
  description = "RunSync repository development tools";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in {
      devShells = eachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            (if builtins.hasAttr "go_1_26" pkgs then pkgs.go_1_26 else pkgs.go)
            postgresql_18
            caddy
            cloudflared
            golangci-lint
            gotools
            govulncheck
          ]
          ++ pkgs.lib.optionals (builtins.hasAttr "staticcheck" pkgs) [ pkgs.staticcheck ]
          ++ pkgs.lib.optionals (pkgs.stdenv.isDarwin && builtins.hasAttr "xcodegen" pkgs) [ pkgs.xcodegen ];
        };
      });
      formatter = eachSystem (pkgs: pkgs.nixfmt);
      packages = eachSystem (pkgs: {
        server = pkgs.buildGoModule {
          pname = "runsync-server";
          version = "0.1.0";
          src = ./server;
          vendorHash = "sha256-3Lu1zdVyL9TfHrkdb5ISsAYp5bjFcxN0faIasDMwdJg=";
          subPackages = [ "cmd/runsync" ];
        };
      });
      checks = eachSystem (pkgs: {
        server = self.packages.${pkgs.stdenv.hostPlatform.system}.server;
      });
    };
}
