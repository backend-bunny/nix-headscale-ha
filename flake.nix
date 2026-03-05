{
  description = "Headscale High-Availability on NixOS — Litestream + custom leader election + Caddy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }: let
    # -----------------------------------------------------------------------
    # Package overlay: adds headscale-leader-election to pkgs
    # -----------------------------------------------------------------------
    overlay = final: prev: {
      headscale-leader-election = final.callPackage ./leader-election/default.nix {};
    };

    # -----------------------------------------------------------------------
    # NixOS modules exported by this flake
    # -----------------------------------------------------------------------
    nixosModules = {
      headscale-ha = import ./modules/headscale-ha.nix;
      leader-election = import ./modules/leader-election.nix;
      litestream-ha = import ./modules/litestream-ha.nix;
      headscale-watchdog = import ./modules/headscale-watchdog.nix;
      caddy-headscale = import ./modules/caddy-headscale.nix;
    };
  in
    # Per-system outputs (packages, devShell, checks)
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [overlay];
        };
      in {
        formatter = pkgs.alejandra;

        # Build the leader-election binary: `nix build .#headscale-leader-election`
        packages = {
          headscale-leader-election = pkgs.headscale-leader-election;
          default = pkgs.headscale-leader-election;

          # Caddy with the caddy-dns/cloudflare plugin compiled in.
          # Used by the Cloudflare DNS-01 TLS option in caddy-headscale.nix.
          #
          # Bootstrap: if the build fails with a hash mismatch, run:
          #   nix build .#caddy-cloudflare 2>&1 | grep 'got:'
          # and update the hash below.
          caddy-cloudflare = pkgs.caddy.withPlugins {
            plugins = ["github.com/caddy-dns/cloudflare@v0.2.1"];
            # Replace with the hash printed by the bootstrap command above.
            hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          };
        };

        # Development shell: `nix develop`
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            go
            gopls
            gotools
            delve
            headscale
            litestream
            caddy
          ];
        };

        # Checks exposed by `nix flake check`
        checks =
          {
            # Fast build smoke-test (no VM required)
            leader-election-build = pkgs.headscale-leader-election;
          }
          # Full e2e integration test (4 QEMU VMs, ~5-10 min).
          # Only supported on x86_64-linux (nixosTest requires QEMU/KVM).
          # Run with:  nix build .#checks.x86_64-linux.e2e -L
          # Or:        ./tests/run-e2e.sh
          // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
            e2e = import ./tests/e2e-test.nix {
              inherit pkgs overlay nixosModules;
              lib = pkgs.lib;
            };
          };
      }
    )
    // {
      # System-independent outputs
      inherit overlay nixosModules;

      # -----------------------------------------------------------------------
      # Example NixOS configurations (two-node cluster)
      # Deploy with: nixos-rebuild switch --flake .#node1
      # -----------------------------------------------------------------------
      nixosConfigurations = {
        node1 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            {nixpkgs.overlays = [overlay];}
            nixosModules.headscale-ha
            ./nixos/node1.nix
          ];
        };

        node2 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            {nixpkgs.overlays = [overlay];}
            nixosModules.headscale-ha
            ./nixos/node2.nix
          ];
        };

        node3 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            {nixpkgs.overlays = [overlay];}
            nixosModules.headscale-ha
            ./nixos/node3.nix
          ];
        };
      };
    };
}
