# modules/headscale-ha.nix
#
# Top-level NixOS module for the headscale HA stack.
#
# This module imports the four sub-modules and wires them together under a
# single `services.headscaleHa` option namespace so that a host configuration
# only needs one import and one options block.
#
# Architecture diagram
# ────────────────────
#
#  ┌─────────────────────────────────────────────────────────────────────────┐
#  │                         Each cluster node                               │
#  │                                                                         │
#  │  ┌──────────────────────┐   gossip   ┌──────────────────────┐           │
#  │  │  leader-election     │◀──────────▶│  leader-election     │  (peers)  │
#  │  │  :50555              │            │  :50555 (other node) │           │
#  │  └──────────┬───────────┘            └──────────────────────┘           │
#  │             │ /status (isLeader)                                        │
#  │  ┌──────────▼───────────┐                                               │
#  │  │  headscale-watchdog  │  (systemd loop, polls every 5 s)              │
#  │  │  — promote  ──────────────────────────────────────────┐              │
#  │  │  — demote   ──────────────────────────────────────┐   │              │
#  │  └──────────────────────┘                            │   │              │
#  │                                                      │   │              │
#  │  ┌───────────────────┐  ┌──────────────────────┐     │   │              │
#  │  │  litestream-      │  │  litestream-         │     │   │              │
#  │  │  restore          │  │  replicate           │◀────┘   │              │
#  │  │  (one-shot)       │  │  (continuous)        │         │              │
#  │  └─────────┬─────────┘  └──────────────────────┘         │              │
#  │            │ restore DB                 replicates ──▶ S3│              │
#  │  ┌─────────▼─────────────────────────────────────────┐   │              │
#  │  │                  headscale                        │◀──┘              │
#  │  │  HTTP :8080   gRPC :50443                         │                  │
#  │  └───────────────────────────────────────────────────┘                  │
#  │                                                                         │
#  │  ┌──────────────────────────────────────────────────────┐               │
#  │  │  Caddy — forwards to the PRIMARY node only           │               │
#  │  │  health_uri /leader :50555  (routes around standbys) │               │
#  │  └──────────────────────────────────────────────────────┘               │
#  └─────────────────────────────────────────────────────────────────────────┘
#
# Minimal usage
# ─────────────
#
#   imports = [ inputs.nix-headscale-ha.nixosModules.headscale-ha ];
#
#   services.headscaleHa = {
#     enable = true;
#
#     node = {
#       id       = "node1";
#       priority = 10;         # lower = preferred primary
#       peers    = [ "http://192.168.1.12:50555" ];
#     };
#
#     litestream.replica = {
#       type   = "s3";
#       bucket = "my-headscale-backups";
#       endpoint = "https://garage.internal:9000";
#     };
#     litestream.credentialsFile = "/run/secrets/litestream";
#
#     caddy = {
#       serverName = "headscale.example.com";
#       acmeEmail  = "admin@example.com";
#       nodes = [
#         { address = "192.168.1.11"; }
#         { address = "192.168.1.12"; }
#       ];
#     };
#
#     headscale.settings = {
#       server_url = "https://headscale.example.com";
#       # ... headscale config.yaml options ...
#     };
#   };
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.headscaleHa;
  inherit (lib) mkIf mkEnableOption mkOption types;
in {
  imports = [
    ./leader-election.nix
    ./litestream-ha.nix
    ./headscale-watchdog.nix
    ./caddy-headscale.nix
  ];

  # ---------------------------------------------------------------------------
  # Top-level options
  # ---------------------------------------------------------------------------
  options.services.headscaleHa = {
    enable = mkEnableOption "headscale High Availability stack (Litestream + custom leader election + Caddy)";

    # ── Node identity ──────────────────────────────────────────────────────
    node = {
      id = mkOption {
        type = types.str;
        description = "Unique, stable node identifier.";
        example = "node1";
      };

      priority = mkOption {
        type = types.int;
        default = 100;
        description = "Election priority.  Lower value = preferred primary.";
        example = 10;
      };

      peers = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Advertise URLs of the other cluster nodes (not self).";
        example = ["http://192.168.1.12:50555"];
      };

      leaderElectionPort = mkOption {
        type = types.port;
        default = 50555;
        description = "Port for the leader-election HTTP API.";
      };

      openLeaderElectionFirewall = mkOption {
        type = types.bool;
        default = false;
        description = "Open the leader-election port in the NixOS firewall.";
      };

      # -- mTLS peer authentication ---------------------------------------
      # Mirror of services.headscaleLeaderElection.tls.
      # All three files must be set together or left null.
      tls = {
        caFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''            Cluster CA certificate (PEM).  Distribute the same
                        file to all nodes.  Leave null to run without mTLS.
          '';
          example = "/run/secrets/le-ca.crt";
        };
        certFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''            This node's TLS certificate (PEM) signed by the
                        cluster CA.  Must contain the node's IP as an IP SAN.
          '';
          example = "/run/secrets/le-node1.crt";
        };
        keyFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "This node's TLS private key (PEM).";
          example = "/run/secrets/le-node1.key";
        };
        listenAddr = mkOption {
          type = types.str;
          default = ":50556";
          description = "mTLS peer-gossip listener address.  Peers must use https:// URLs on this port.";
        };
      };
    };

    # ── Litestream ─────────────────────────────────────────────────────────
    litestream = {
      dbPath = mkOption {
        type = types.path;
        default = "/var/lib/headscale/db.sqlite3";
        description = "Path to the headscale SQLite database file.";
      };

      credentialsFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          EnvironmentFile with S3 credentials:
            LITESTREAM_ACCESS_KEY_ID=...
            LITESTREAM_SECRET_ACCESS_KEY=...
        '';
        example = "/run/secrets/litestream";
      };

      replica = {
        type = mkOption {
          type = types.enum ["s3" "file" "sftp"];
          default = "s3";
        };
        bucket = mkOption {
          type = types.str;
          default = "";
        };
        path = mkOption {
          type = types.str;
          default = "headscale-db";
        };
        endpoint = mkOption {
          type = types.str;
          default = "";
        };
        region = mkOption {
          type = types.str;
          default = "us-east-1";
        };
        filePath = mkOption {
          type = types.str;
          default = "/var/lib/litestream-replica";
        };
        sftpHost = mkOption {
          type = types.str;
          default = "";
        };
        sftpUser = mkOption {
          type = types.str;
          default = "litestream";
        };
        sftpPath = mkOption {
          type = types.str;
          default = "/var/lib/litestream-replica/headscale";
        };
        retention = mkOption {
          type = types.str;
          default = "24h";
        };
        syncInterval = mkOption {
          type = types.str;
          default = "1s";
        };
      };
    };

    # ── Headscale ──────────────────────────────────────────────────────────
    headscale = {
      settings = mkOption {
        type = types.attrs;
        default = {};
        description = "Attribute set merged into services.headscale.settings.";
        example = {
          server_url = "https://headscale.example.com";
          listen_addr = "0.0.0.0:8080";
          grpc_listen_addr = "0.0.0.0:50443";
          metrics_listen_addr = "127.0.0.1:9090";
          log.level = "info";
          prefixes = {
            v4 = "100.64.0.0/10";
            v6 = "fd7a:115c:a1e0::/48";
            allocation = "sequential";
          };
        };
      };
    };

    # ── Caddy ──────────────────────────────────────────────────────────────
    caddy = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Caddy reverse proxy on this node.";
      };

      serverName = mkOption {
        type = types.str;
        description = "FQDN for the headscale service.";
        example = "headscale.example.com";
      };

      acmeEmail = mkOption {
        type = types.str;
        default = "";
        description = "ACME email address for Let's Encrypt. Empty = no automatic ACME.";
      };

      tls.extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = "Extra Caddy TLS directives, e.g. 'tls internal'.";
      };

      # -- Cloudflare DNS-01 TLS ---------------------------------------------
      cloudflare = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = "Use Cloudflare DNS-01 ACME challenge for TLS (no inbound HTTP required).";
        };
        tokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''            Path to a systemd EnvironmentFile containing:
                        CLOUDFLARE_DNS_API_TOKEN=cfxxxxxxxxxxxxxxxx
          '';
          example = "/run/secrets/caddy-cloudflare-token";
        };
        caddyPackage = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = ''            Override the Caddy package used when cloudflare.enable = true.
                        When null the default from services.caddyHeadscale is used, which calls
                        pkgs.caddy.withPlugins with the cloudflare plugin at a pinned version.
                        See the caddy-cloudflare package exported by this flake for a ready-to-use
                        build: inputs.nix-headscale-ha.packages.''${system}.caddy-cloudflare
          '';
        };
      };

      nodes = mkOption {
        type = types.listOf (types.submodule {
          options = {
            address = mkOption {type = types.str;};
            httpPort = mkOption {
              type = types.port;
              default = 8080;
            };
            grpcPort = mkOption {
              type = types.port;
              default = 50443;
            };
          };
        });
        default = [];
      };
    };

    # ── Watchdog ───────────────────────────────────────────────────────────
    watchdog = {
      pollInterval = mkOption {
        type = types.int;
        default = 5;
        description = "Seconds between leadership polls in the watchdog.";
      };
      startupGrace = mkOption {
        type = types.int;
        default = 5;
        description = "Seconds to wait for the cluster to converge after boot.";
      };

      # DNS failover via Cloudflare — mirrors services.headscaleWatchdog.cloudflare.
      # tokenFile and recordName have sensible defaults drawn from the caddy block.
      dns = {
        enable = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Update the headscale Cloudflare DNS A record on promotion.
            Requires <option>caddy.cloudflare.enable = true</option> (or an
            explicit <option>watchdog.dns.tokenFile</option>).
          '';
        };

        tokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Path to the Cloudflare token EnvironmentFile.  When null, falls
            back to <option>caddy.cloudflare.tokenFile</option>.
          '';
          example = "/run/secrets/caddy-cloudflare-token";
        };

        zoneId = mkOption {
          type = types.str;
          default = "";
          description = "Cloudflare Zone ID containing the headscale DNS record.";
          example = "b6558c4a7b3b0a1c62d5f8e9d0f12345";
        };

        recordName = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            DNS A record to update on promotion.  When null, falls back to
            <option>caddy.serverName</option>.
          '';
          example = "headscale.example.com";
        };

        nodeAddress = mkOption {
          type = types.str;
          default = "";
          description = "Public IPv4 address of this node, written into the A record on promotion.";
          example = "203.0.113.11";
        };

        ttl = mkOption {
          type = types.int;
          default = 60;
          description = "DNS TTL in seconds (60 = Cloudflare non-proxied minimum).";
        };
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Wire up sub-modules when headscaleHa.enable = true
  # ---------------------------------------------------------------------------
  config = mkIf cfg.enable {
    # ── Leader election ───────────────────────────────────────────────────
    services.headscaleLeaderElection = {
      enable = true;
      nodeId = cfg.node.id;
      nodePriority = cfg.node.priority;
      listenAddr = ":${toString cfg.node.leaderElectionPort}";
      peers = cfg.node.peers;
      openFirewall = cfg.node.openLeaderElectionFirewall;
      tls.caFile = cfg.node.tls.caFile;
      tls.certFile = cfg.node.tls.certFile;
      tls.keyFile = cfg.node.tls.keyFile;
      tls.listenAddr = cfg.node.tls.listenAddr;
    };

    # ── Litestream ────────────────────────────────────────────────────────
    services.litestreamHa = {
      enable = true;
      dbPath = cfg.litestream.dbPath;
      credentialsFile = cfg.litestream.credentialsFile;
      replica = cfg.litestream.replica;
    };

    # ── Headscale (NixOS built-in service) ───────────────────────────────
    services.headscale = {
      enable = true;
      # Merge caller-supplied settings with HA-required defaults.
      settings =
        lib.recursiveUpdate {
          # Default listen addresses — override in headscale.settings.
          listen_addr = "0.0.0.0:8080";
          grpc_listen_addr = "0.0.0.0:50443";
          # Store DB in the expected location.
          database = {
            type = "sqlite3";
            sqlite = {
              path = cfg.litestream.dbPath;
            };
          };
        }
        cfg.headscale.settings;
    };

    # ── Watchdog ──────────────────────────────────────────────────────────
    services.headscaleWatchdog = lib.mkMerge [
      {
        enable = true;
        leaderElectionBaseUrl = "http://127.0.0.1:${toString cfg.node.leaderElectionPort}";
        pollInterval = cfg.watchdog.pollInterval;
        startupGrace = cfg.watchdog.startupGrace;
      }
      (lib.mkIf cfg.watchdog.dns.enable {
        cloudflare = {
          enable = true;
          # Fall back to caddy's tokenFile when not explicitly set.
          tokenFile =
            if cfg.watchdog.dns.tokenFile != null
            then cfg.watchdog.dns.tokenFile
            else cfg.caddy.cloudflare.tokenFile;
          zoneId = cfg.watchdog.dns.zoneId;
          # Fall back to caddy.serverName as the record name.
          recordName =
            if cfg.watchdog.dns.recordName != null
            then cfg.watchdog.dns.recordName
            else cfg.caddy.serverName;
          nodeAddress = cfg.watchdog.dns.nodeAddress;
          ttl = cfg.watchdog.dns.ttl;
        };
      })
    ];

    # ── Caddy ─────────────────────────────────────────────────────────────
    services.caddyHeadscale = mkIf cfg.caddy.enable (lib.mkMerge [
      {
        enable = true;
        serverName = cfg.caddy.serverName;
        acmeEmail = cfg.caddy.acmeEmail;
        tls.extraConfig = cfg.caddy.tls.extraConfig;
        nodes = cfg.caddy.nodes;
        leaderElectionPort = cfg.node.leaderElectionPort;
      }
      (mkIf cfg.caddy.cloudflare.enable {
        cloudflare.enable = true;
        cloudflare.tokenFile = cfg.caddy.cloudflare.tokenFile;
      })
      (mkIf (cfg.caddy.cloudflare.enable && cfg.caddy.cloudflare.caddyPackage != null) {
        cloudflare.caddyPackage = cfg.caddy.cloudflare.caddyPackage;
      })
    ]);
  };
}
