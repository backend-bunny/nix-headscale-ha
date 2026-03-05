# modules/leader-election.nix
#
# NixOS module for the headscale-leader-election daemon.
# This module is imported automatically by headscale-ha.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.headscaleLeaderElection;
  inherit (lib) mkIf mkEnableOption mkOption types;
in {
  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------
  options.services.headscaleLeaderElection = {
    enable = mkEnableOption "headscale leader-election daemon";

    package = mkOption {
      type = types.package;
      default = pkgs.headscale-leader-election;
      description = "The headscale-leader-election package to use.";
    };

    nodeId = mkOption {
      type = types.str;
      description = "Unique, stable identifier for this node (e.g. \"node1\").";
      example = "node1";
    };

    nodePriority = mkOption {
      type = types.int;
      default = 100;
      description = ''
        Election priority.  The node with the *lowest* value among all healthy
        nodes becomes the leader.  Use 10 for the preferred primary, 20 for the
        first fallback, etc.
      '';
      example = 10;
    };

    listenAddr = mkOption {
      type = types.str;
      default = ":50555";
      description = "Address:port on which the HTTP API listens.";
      example = ":50555";
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        Advertise URLs of every other node in the cluster.
        Do NOT include this node's own URL.
      '';
      example = ["http://192.168.1.12:50555" "http://192.168.1.13:50555"];
    };

    heartbeatInterval = mkOption {
      type = types.str;
      default = "2s";
      description = "Go duration string for the peer probe interval.";
    };

    deadThreshold = mkOption {
      type = types.str;
      default = "8s";
      description = "Go duration string: time without response before a peer is considered dead.";
    };

    httpTimeout = mkOption {
      type = types.str;
      default = "2s";
      description = "Go duration string for per-probe HTTP timeout.";
    };

    # -- mTLS peer authentication ----------------------------------------
    # When caFile/certFile/keyFile are all set the daemon opens a second
    # listener on tls.listenAddr that requires and verifies client certificates
    # signed by the cluster CA.  Peers must point their probe URLs at this
    # address.  The plain HTTP listener (listenAddr) remains open for the
    # watchdog and Caddy health checks.
    tls = {
      caFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''          Path to the cluster CA certificate (PEM).
                    Mandatory when mTLS is desired.  Distribute this file to all nodes;
                    it is used to verify both remote peer certificates (client role) and
                    incoming peer connections (server role).
                    Leave null to run without mTLS (dev / LAN-only deployments).
        '';
        example = "/run/secrets/le-ca.crt";
      };

      certFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''          Path to this node's TLS certificate (PEM) signed by
                    the cluster CA.  The certificate must include the node's IP address
                    as a Subject Alternative Name (IP SAN) so that peer connections to
                    the node's IP are validated correctly.
        '';
        example = "/run/secrets/le-node1.crt";
      };

      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to this node's TLS private key (PEM).";
        example = "/run/secrets/le-node1.key";
      };

      listenAddr = mkOption {
        type = types.str;
        default = ":50556";
        description = ''          Address:port for the mTLS peer-gossip listener.
                    Only opened when caFile, certFile, and keyFile are all set.
                    Peers in the peers list must use https:// URLs pointing at this port.
        '';
        example = ":50556";
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the leader-election API port in the NixOS firewall.";
    };
  };

  # ---------------------------------------------------------------------------
  # Implementation
  # ---------------------------------------------------------------------------
  config = mkIf cfg.enable {
    assertions = [
      {
        # All three TLS files must be set together or not at all.
        assertion =
          (cfg.tls.caFile == null)
          == (cfg.tls.certFile == null)
          && (cfg.tls.certFile == null) == (cfg.tls.keyFile == null);
        message = ''          services.headscaleLeaderElection.tls: caFile, certFile,
                    and keyFile must all be set or all null (currently only some are set).
        '';
      }
    ];

    # Open firewall port(s) if requested.
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall (
      [(lib.toInt (lib.last (lib.splitString ":" cfg.listenAddr)))]
      ++ lib.optional (cfg.tls.caFile != null)
      (lib.toInt (lib.last (lib.splitString ":" cfg.tls.listenAddr)))
    );

    systemd.services.headscale-leader-election = {
      description = "Headscale leader-election daemon";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      environment =
        {
          NODE_ID = cfg.nodeId;
          NODE_PRIORITY = toString cfg.nodePriority;
          LISTEN_ADDR = cfg.listenAddr;
          TLS_LISTEN_ADDR = cfg.tls.listenAddr;
          PEERS = lib.concatStringsSep "," cfg.peers;
          HEARTBEAT_INTERVAL = cfg.heartbeatInterval;
          DEAD_THRESHOLD = cfg.deadThreshold;
          HTTP_TIMEOUT = cfg.httpTimeout;
        }
        // lib.optionalAttrs (cfg.tls.caFile != null) {
          TLS_CA_FILE = cfg.tls.caFile;
          TLS_CERT_FILE = cfg.tls.certFile;
          TLS_KEY_FILE = cfg.tls.keyFile;
        };

      serviceConfig = {
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/leader-election"
            "--node-id=${cfg.nodeId}"
            "--node-priority=${toString cfg.nodePriority}"
            "--listen-addr=${cfg.listenAddr}"
            "--tls-listen-addr=${cfg.tls.listenAddr}"
            "--peers=${lib.concatStringsSep "," cfg.peers}"
            "--heartbeat-interval=${cfg.heartbeatInterval}"
            "--dead-threshold=${cfg.deadThreshold}"
            "--http-timeout=${cfg.httpTimeout}"
          ]
          ++ lib.optionals (cfg.tls.caFile != null) [
            "--tls-ca-file=${cfg.tls.caFile}"
            "--tls-cert-file=${cfg.tls.certFile}"
            "--tls-key-file=${cfg.tls.keyFile}"
          ]
        );

        Restart = "on-failure";
        RestartSec = "3s";
        DynamicUser = true;

        # Systemd hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallFilter = ["@system-service"];
        SystemCallErrorNumber = "EPERM";

        # Allow read-only access to TLS cert/key files when mTLS is enabled.
        ReadOnlyPaths = lib.optionals (cfg.tls.caFile != null) [
          cfg.tls.caFile
          cfg.tls.certFile
          cfg.tls.keyFile
        ];
      };
    };
  };
}
