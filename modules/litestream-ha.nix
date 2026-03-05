# modules/litestream-ha.nix
#
# NixOS module that configures Litestream for headscale HA.
#
# Litestream role in this stack
# ─────────────────────────────
#  • The PRIMARY node runs headscale + `litestream replicate`, streaming
#    every SQLite WAL frame to an S3-compatible object store in real time.
#
#  • STANDBY nodes do NOT run headscale.  They optionally run
#    `litestream replicate` in "shadow" mode to keep a warm local copy of
#    the WAL (saves restore time on promotion).
#
#  • On PROMOTION (standby → primary) the watchdog first runs a one-shot
#    `litestream restore` to pull the latest snapshot + WAL frames from S3,
#    then starts headscale, then starts continuous replication.
#
# This module only installs the config file and the two systemd services
# (litestream-restore.service and litestream-replicate.service).
# The watchdog (headscale-watchdog.nix) decides when to start/stop them.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.litestreamHa;
  inherit (lib) mkIf mkEnableOption mkOption types literalExpression;

  # Render the litestream YAML config file from Nix options.
  # Use pkgs.formats.yaml to avoid indentation bugs from Nix string interpolation.
  replicaAttrs =
    {type = cfg.replica.type;}
    // lib.optionalAttrs (cfg.replica.type == "s3") {
      bucket = cfg.replica.bucket;
      path = cfg.replica.path;
      endpoint = cfg.replica.endpoint;
      region = cfg.replica.region;
    }
    // lib.optionalAttrs (cfg.replica.type == "file") {
      path = cfg.replica.filePath;
    }
    // lib.optionalAttrs (cfg.replica.type == "sftp") {
      host = cfg.replica.sftpHost;
      user = cfg.replica.sftpUser;
      path = cfg.replica.sftpPath;
    }
    // {
      retention = cfg.replica.retention;
      "sync-interval" = cfg.replica.syncInterval;
    };

  litestreamConfig = (pkgs.formats.yaml {}).generate "litestream.yml" {
    dbs = [
      {
        path = cfg.dbPath;
        replicas = [replicaAttrs];
      }
    ];
  };
in {
  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------
  options.services.litestreamHa = {
    enable = mkEnableOption "Litestream HA replication for headscale";

    package = mkOption {
      type = types.package;
      default = pkgs.litestream;
      description = "The litestream package to use.";
    };

    dbPath = mkOption {
      type = types.path;
      default = "/var/lib/headscale/db.sqlite3";
      description = "Absolute path to the headscale SQLite database file.";
    };

    # Credentials are supplied via environment — never hard-coded in the config
    # file.  Set these through a secrets manager or an EnvironmentFile.
    credentialsFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a systemd EnvironmentFile containing S3 credentials:
          LITESTREAM_ACCESS_KEY_ID=...
          LITESTREAM_SECRET_ACCESS_KEY=...
        Use a secrets manager (agenix, sops-nix, etc.) to provision this file.
      '';
      example = "/run/secrets/litestream-credentials";
    };

    replica = {
      type = mkOption {
        type = types.enum ["s3" "file" "sftp"];
        default = "s3";
        description = "Litestream replica backend type.";
      };

      # S3 / S3-compatible (AWS S3, Cloudflare R2, Garage, etc.)
      bucket = mkOption {
        type = types.str;
        default = "";
        description = "S3 bucket name.";
        example = "headscale-ha-backup";
      };
      path = mkOption {
        type = types.str;
        default = "headscale-db";
        description = "Key prefix inside the S3 bucket.";
      };
      endpoint = mkOption {
        type = types.str;
        default = "";
        description = "S3 endpoint URL. Leave empty for AWS S3. Set for Garage / Cloudflare R2 / etc.";
        example = "https://garage.internal:9000";
      };
      region = mkOption {
        type = types.str;
        default = "us-east-1";
        description = "S3 region (ignored by Garage/R2 but required by the driver).";
      };

      # File backend (useful for NFS / shared volumes in local dev)
      filePath = mkOption {
        type = types.str;
        default = "/var/lib/litestream-replica";
        description = "Destination path for the 'file' replica backend.";
      };

      # SFTP backend (direct node-to-node replication without object storage)
      sftpHost = mkOption {
        type = types.str;
        default = "";
        description = "SFTP host for the 'sftp' replica backend.";
        example = "192.168.1.12";
      };
      sftpUser = mkOption {
        type = types.str;
        default = "litestream";
        description = "SFTP user.";
      };
      sftpPath = mkOption {
        type = types.str;
        default = "/var/lib/litestream-replica/headscale";
        description = "Remote path on the SFTP server.";
      };

      # Common
      retention = mkOption {
        type = types.str;
        default = "24h";
        description = "Litestream Go duration for how long to keep old WAL frames.";
      };
      syncInterval = mkOption {
        type = types.str;
        default = "1s";
        description = "Litestream Go duration for WAL sync interval.";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Implementation
  # ---------------------------------------------------------------------------
  config = mkIf cfg.enable {
    # Make the litestream binary available in PATH for interactive debugging.
    environment.systemPackages = [cfg.package];

    # Install the config file.
    environment.etc."litestream/litestream.yml".source = litestreamConfig;

    # ------------------------------------------------------------------
    # litestream-restore.service
    #   One-shot: pull the latest snapshot + WAL frames from the replica
    #   store and write them into dbPath.  Run by the watchdog before
    #   starting headscale on a newly elected primary.
    # ------------------------------------------------------------------
    systemd.services.litestream-restore = {
      description = "Litestream one-shot restore for headscale DB";
      # Explicitly NOT wantedBy anything — started on demand by watchdog.

      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = false;
        User = "headscale";
        Group = "headscale";
        # Create the DB directory before the namespace step (ReadWritePaths
        # requires the path to already exist when ProtectSystem=strict is set).
        StateDirectory =
          lib.mkIf (lib.hasPrefix "/var/lib/" cfg.dbPath)
          (lib.removePrefix "/var/lib/" (builtins.dirOf cfg.dbPath));

        ExecStart = pkgs.writeShellScript "litestream-restore.sh" ''
          set -euo pipefail
          CONFIG=/etc/litestream/litestream.yml
          DB=${cfg.dbPath}

          echo "Attempting litestream restore from replica..."

          # --if-replica-exists: exit 0 (no error) when store is empty.
          # This handles first-boot where nothing has been replicated yet.
          if ${cfg.package}/bin/litestream restore \
              -config "$CONFIG" \
              -if-replica-exists \
              "$DB"; then
            echo "Restore complete: $DB"
          else
            echo "No replica data found — starting with a fresh database."
          fi
        '';

        EnvironmentFile = mkIf (cfg.credentialsFile != null) cfg.credentialsFile;

        # Security
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [(builtins.dirOf cfg.dbPath)];
        PrivateTmp = true;
      };
    };

    # ------------------------------------------------------------------
    # litestream-replicate.service
    #   Long-running: stream WAL frames to the replica store.
    #   Started by the watchdog after headscale is up on the primary.
    #   Stopped by the watchdog when the node loses leadership.
    # ------------------------------------------------------------------
    systemd.services.litestream-replicate = {
      description = "Litestream continuous replication for headscale DB";
      # Explicitly NOT wantedBy anything — started on demand by watchdog.

      after = ["headscale.service"];
      bindsTo = ["headscale.service"];

      serviceConfig = {
        Type = "simple";
        User = "headscale";
        Group = "headscale";

        ExecStart = "${cfg.package}/bin/litestream replicate -config /etc/litestream/litestream.yml";

        Restart = "on-failure";
        RestartSec = "5s";

        EnvironmentFile = mkIf (cfg.credentialsFile != null) cfg.credentialsFile;

        # Security
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ReadWritePaths = [(builtins.dirOf cfg.dbPath)];
        PrivateTmp = true;
      };
    };
  };
}
