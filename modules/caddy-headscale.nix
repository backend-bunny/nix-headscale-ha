# modules/caddy-headscale.nix
#
# NixOS module that configures Caddy as the HA-aware reverse proxy for
# headscale.
#
# How active failover routing works
# ──────────────────────────────────
# Caddy's `reverse_proxy` supports an active health check.  We point that
# health check at each node's leader-election daemon endpoint (/leader on
# port 50555).  Only the current primary responds with HTTP 200 — all
# standby nodes return 503.  Caddy therefore naturally routes all traffic
# to the single healthy (=primary) upstream, with no extra scripting needed.
#
# Supported traffic types
# ───────────────────────
# • HTTPS (port 443) — REST API, web UI, Tailscale client registration
# • gRPC-over-TLS (port 443, h2) — Tailscale coordination over gRPC
# • Caddy handles TLS termination and proxies plain-HTTP/h2c upstream.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.caddyHeadscale;
  inherit (lib) mkIf mkEnableOption mkOption types literalExpression;

  # Build the list of upstream dial-addresses for Caddy (host:httpPort).
  upstreamDialAddrs =
    lib.concatMapStringsSep "\n        " (
      node: "to ${node.address}:${toString node.httpPort}"
    )
    cfg.nodes;

  # Effective Caddy package: swap in the cloudflare-capable build when the
  # DNS-01 challenge is enabled.
  effectiveCaddyPackage =
    if cfg.cloudflare.enable
    then cfg.cloudflare.caddyPackage
    else pkgs.caddy;

  # Build health_uri lines that point to each node's leader-election port.
  # Caddy's health_port applies globally to all upstreams so we rely on
  # the convention that every node exposes the leader-election API on the
  # same port.
  caddyFile = ''
    {
      # Global options
      ${lib.optionalString (cfg.acmeEmail != "") "email ${cfg.acmeEmail}"}
      ${lib.optionalString cfg.cloudflare.enable
      "# DNS-01 challenge via Cloudflare — token loaded from EnvironmentFile\n      acme_dns cloudflare {env.CLOUDFLARE_DNS_API_TOKEN}"}
      admin off
    }

    ${cfg.serverName} {
      # ---------------------------------------------------------------
      # TLS — Caddy provisions and auto-renews certificates via ACME.
      # For internal/LAN deployments set acmeEmail = "" and add:
      #   tls /path/to/cert.pem /path/to/key.pem
      # or use the tls.extraConfig option below.
      # ---------------------------------------------------------------
      ${cfg.tls.extraConfig}

      # ---------------------------------------------------------------
      # Log
      # ---------------------------------------------------------------
      log {
        output stdout
        format json
        level  INFO
      }

      # ---------------------------------------------------------------
      # Headscale gRPC — matched by content-type header.
      # Caddy proxies these over h2c to headscale's gRPC port.
      # ---------------------------------------------------------------
      @grpc {
        header Content-Type application/grpc*
      }
      reverse_proxy @grpc {
        ${lib.concatMapStringsSep "\n        " (
        n: "to ${n.address}:${toString n.grpcPort}"
      )
      cfg.nodes}

        # Use HTTP/2 cleartext transport to the backend (headscale gRPC).
        transport http {
          versions h2c 2
        }

        # Active health check: only route to the node whose
        # leader-election daemon returns 200.
        health_uri      /leader
        health_port     ${toString cfg.leaderElectionPort}
        health_interval ${cfg.healthInterval}
        health_timeout  ${cfg.healthTimeout}
        health_status   200
      }

      # ---------------------------------------------------------------
      # Headscale HTTP (REST API + web UI).
      # ---------------------------------------------------------------
      reverse_proxy {
        ${lib.concatMapStringsSep "\n        " (
        n: "to ${n.address}:${toString n.httpPort}"
      )
      cfg.nodes}

        # Preserve important headers for headscale's address detection.
        header_up Host              {upstream_hostport}
        header_up X-Real-IP         {remote_host}
        header_up X-Forwarded-For   {remote_host}
        header_up X-Forwarded-Proto {scheme}

        # Active health check (same leader-election endpoint).
        health_uri      /leader
        health_port     ${toString cfg.leaderElectionPort}
        health_interval ${cfg.healthInterval}
        health_timeout  ${cfg.healthTimeout}
        health_status   200
      }
    }

    # Redirect plain HTTP to HTTPS.
    http://${cfg.serverName} {
      redir https://{host}{uri} permanent
    }

    ${cfg.extraConfig}
  '';
in {
  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------
  options.services.caddyHeadscale = {
    enable = mkEnableOption "Caddy HA reverse proxy for headscale";

    serverName = mkOption {
      type = types.str;
      description = "Fully-qualified domain name served by Caddy (e.g. headscale.example.com).";
      example = "headscale.example.com";
    };

    acmeEmail = mkOption {
      type = types.str;
      default = "";
      description = "Email address for Let's Encrypt / ACME certificate requests. Leave empty to disable automatic ACME.";
      example = "admin@example.com";
    };

    tls.extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra Caddy TLS directives inserted verbatim into the site block, e.g. 'tls internal' for local CA.";
      example = "tls internal";
    };

    # -- Cloudflare DNS-01 TLS -----------------------------------------------
    cloudflare = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''          Obtain TLS certificates via the ACME DNS-01 challenge using the
                    Cloudflare API.  This avoids the need for inbound HTTP-01 traffic and
                    works for internal/private hostnames.

                    Requires a Caddy build that includes the caddy-dns/cloudflare plugin.
                    Set <option>cloudflare.caddyPackage</option> to
                    <literal>pkgs.caddy-cloudflare</literal> (exposed by this flake) or
                    build your own with <literal>pkgs.caddy.withPlugins</literal>.
        '';
      };

      tokenFile = mkOption {
        type = types.path;
        description = ''          Path to a file whose content is a systemd EnvironmentFile
                    containing the Cloudflare API token in the form:

                      CLOUDFLARE_DNS_API_TOKEN=cfxxxxxxxxxxxxxxxx

                    The file is loaded as a systemd EnvironmentFile so it must use that
                    exact KEY=VALUE format (no quotes, no export keyword).

                    Recommended: provision this file with sops-nix or agenix so the
                    token is never stored in the Nix store.  Example (sops-nix):

                      sops.secrets."caddy-cloudflare-token" = {
                        format      = "binary";   # raw file, no sops YAML wrapping
                        # store the file as  CLOUDFLARE_DNS_API_TOKEN=cfxxx
                        owner       = "caddy";
                        path        = "/run/secrets/caddy-cloudflare-token";
                      };
        '';
        example = "/run/secrets/caddy-cloudflare-token";
      };

      caddyPackage = mkOption {
        type = types.package;
        description = ''          Caddy package that includes the caddy-dns/cloudflare plugin.
                    The default value uses <literal>pkgs.caddy.withPlugins</literal> to
                    build caddy with the cloudflare plugin included.

                    You can override this with the <literal>caddy-cloudflare</literal>
                    package exported by this flake:

                      cloudflare.caddyPackage = inputs.nix-headscale-ha.packages.''${system}.caddy-cloudflare;

                    Or build your own:

                      cloudflare.caddyPackage = pkgs.caddy.withPlugins {
                        plugins = [ "github.com/caddy-dns/cloudflare@v0.2.1" ];
                        hash    = "sha256-...";
                      };
        '';
        # Default: build caddy with the cloudflare DNS plugin at a pinned version.
        # Bootstrap the vendorHash once by running:
        #   nix build .#caddy-cloudflare 2>&1 | grep 'got:'
        # then replace the hash below.
        defaultText = literalExpression ''          pkgs.caddy.withPlugins {
                    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.1" ];
                    hash    = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
                  }'';
        default = pkgs.caddy.withPlugins {
          plugins = ["github.com/caddy-dns/cloudflare@v0.2.1"];
          # Run `nix build .#caddy-cloudflare 2>&1 | grep 'got:'` to get the
          # correct hash, then replace the placeholder below.
          hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
        };
      };
    };

    nodes = mkOption {
      description = "List of headscale cluster nodes for Caddy upstreams.";
      type = types.listOf (types.submodule {
        options = {
          address = mkOption {
            type = types.str;
            description = "IP or hostname reachable from Caddy (e.g. 192.168.1.11).";
          };
          httpPort = mkOption {
            type = types.port;
            default = 8080;
            description = "headscale HTTP listen port on this node.";
          };
          grpcPort = mkOption {
            type = types.port;
            default = 50443;
            description = "headscale gRPC listen port on this node.";
          };
        };
      });
      example = literalExpression ''
        [
          { address = "192.168.1.11"; httpPort = 8080; grpcPort = 50443; }
          { address = "192.168.1.12"; httpPort = 8080; grpcPort = 50443; }
        ]
      '';
    };

    leaderElectionPort = mkOption {
      type = types.port;
      default = 50555;
      description = "Port where each node's leader-election daemon listens (for Caddy health checks).";
    };

    healthInterval = mkOption {
      type = types.str;
      default = "5s";
      description = "Caddy active health check interval.";
    };

    healthTimeout = mkOption {
      type = types.str;
      default = "3s";
      description = "Caddy active health check timeout.";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Additional Caddyfile content appended after the generated configuration. Use this to add extra site blocks or snippets.";
      example = ''
        monitoring.example.com {
          reverse_proxy localhost:9090
        }
      '';
    };
  };

  # ---------------------------------------------------------------------------
  # Implementation
  # ---------------------------------------------------------------------------
  config = mkIf cfg.enable {
    assertions = lib.mkMerge [
      [
        {
          assertion = cfg.nodes != [];
          message = "services.caddyHeadscale.nodes must have at least one entry.";
        }
      ]
      (lib.optional cfg.cloudflare.enable {
        assertion = cfg.acmeEmail != "";
        message = "services.caddyHeadscale.acmeEmail must be set when cloudflare.enable = true (required by the ACME client).";
      })
    ];

    services.caddy = {
      enable = true;
      package = effectiveCaddyPackage;
      # Write the generated Caddyfile to the Nix store.
      configFile = pkgs.writeText "Caddyfile" caddyFile;
    };

    # Load the Cloudflare API token into the Caddy systemd service.
    systemd.services.caddy.serviceConfig.EnvironmentFile =
      lib.mkIf cfg.cloudflare.enable (lib.mkDefault cfg.cloudflare.tokenFile);

    # Allow Caddy through the firewall.
    networking.firewall.allowedTCPPorts = [80 443];
  };
}
