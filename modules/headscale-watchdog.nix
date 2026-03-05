# modules/headscale-watchdog.nix
#
# NixOS module for the headscale leadership watchdog.
#
# Role in the HA stack
# ────────────────────
# The watchdog is the orchestration glue.  It runs as a tight loop that:
#
#   1. Polls the local leader-election daemon (/status).
#   2. When THIS node transitions to leader:
#        a. Run `litestream-restore` (one-shot) to pull the latest DB from S3.
#        b. Start headscale.service.
#        c. Start litestream-replicate.service.
#        d. [optional] Update the Cloudflare DNS A record to this node's IP.
#   3. When THIS node loses leadership:
#        a. Stop litestream-replicate.service.
#        b. Stop headscale.service.
#   4. Logs every transition to stdout (visible via `journalctl -u headscale-watchdog`).
#
# The watchdog deliberately starts/stops services with `systemctl` so that
# systemd owns the process lifecycle, PID files, and restart semantics.
#
# Cloudflare DNS update
# ─────────────────────
# When cloudflare.enable = true the watchdog calls the Cloudflare API
# (v4 DNS Records PATCH) after every promotion to point the headscale DNS A
# record to this node's IP.  This ensures Tailscale clients that reconnect
# after a failover are sent directly to the new primary.
#
# The token is read at runtime from cloudflare.tokenFile (a systemd
# EnvironmentFile-format file: CLOUDFLARE_DNS_API_TOKEN=cfxxx).  The file is
# never embedded in the Nix store — provision it with sops-nix or agenix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.headscaleWatchdog;
  cfgCf = cfg.cloudflare;
  inherit (lib) mkIf mkEnableOption mkOption types;

  watchdogScript = pkgs.writeShellApplication {
    name = "headscale-watchdog";

    runtimeInputs = with pkgs; [curl jq systemd coreutils];

    text = ''
      # -----------------------------------------------------------------------
      # headscale-watchdog — promotes/demotes headscale based on leadership.
      # -----------------------------------------------------------------------
      LEADER_URL="${cfg.leaderElectionBaseUrl}/status"
      POLL_INTERVAL=${toString cfg.pollInterval}
      STARTUP_GRACE=${toString cfg.startupGrace}

      # Cloudflare DNS update settings — empty strings when disabled.
      CF_ENABLED="${
        if cfgCf.enable
        then "true"
        else ""
      }"
      CF_TOKEN_FILE="${
        if cfgCf.enable
        then cfgCf.tokenFile
        else ""
      }"
      CF_ZONE_ID="${
        if cfgCf.enable
        then cfgCf.zoneId
        else ""
      }"
      CF_RECORD_NAME="${
        if cfgCf.enable
        then cfgCf.recordName
        else ""
      }"
      CF_NODE_ADDRESS="${
        if cfgCf.enable
        then cfgCf.nodeAddress
        else ""
      }"
      CF_TTL="${
        if cfgCf.enable
        then toString cfgCf.ttl
        else "60"
      }"

      IS_LEADER_PREV=""

      log() { echo "[headscale-watchdog] $*"; }

      wait_for_leader_election() {
        log "Waiting for leader-election daemon to be ready..."
        for _ in $(seq 1 30); do
          if curl -sf "${cfg.leaderElectionBaseUrl}/healthz" >/dev/null 2>&1; then
            log "Leader-election daemon is ready."
            return 0
          fi
          sleep 2
        done
        log "ERROR: leader-election daemon did not become ready in time."
        exit 1
      }

      # update_dns — point the headscale DNS A record to this node's IP via
      # the Cloudflare v4 API.  Reads the API token at runtime so it is never
      # stored in the Nix store.  No-ops immediately when CF_ENABLED is unset.
      update_dns() {
        if [ -z "$CF_ENABLED" ]; then
          return 0
        fi

        log "  DNS: pointing $CF_RECORD_NAME -> $CF_NODE_ADDRESS (zone: $CF_ZONE_ID, TTL: ''${CF_TTL}s)..."

        # Extract token from EnvironmentFile-format secrets file.
        # Format expected: CLOUDFLARE_DNS_API_TOKEN=cfxxxxxxxxxxxxxxxx
        local cf_token
        cf_token=$(grep '^CLOUDFLARE_DNS_API_TOKEN=' "$CF_TOKEN_FILE" | cut -d= -f2-)
        if [ -z "$cf_token" ]; then
          log "  DNS ERROR: CLOUDFLARE_DNS_API_TOKEN not found in $CF_TOKEN_FILE"
          return 1
        fi

        # Step 1: look up the existing A record to get its record ID.
        local list_resp
        list_resp=$(curl -sf --max-time 10 \
          -H "Authorization: Bearer $cf_token" \
          -H "Content-Type: application/json" \
          "https://api.cloudflare.com/client/v4/zones/''${CF_ZONE_ID}/dns_records?name=''${CF_RECORD_NAME}&type=A")

        local record_id
        record_id=$(echo "$list_resp" | jq -r '.result[0].id // empty')
        if [ -z "$record_id" ]; then
          log "  DNS ERROR: no A record found for $CF_RECORD_NAME in zone $CF_ZONE_ID"
          log "  API errors: $(echo "$list_resp" | jq -c '.errors')"
          return 1
        fi

        # Step 2: PATCH only content + ttl — leaves proxy status and name intact.
        local patch_resp
        patch_resp=$(curl -sf --max-time 10 -X PATCH \
          -H "Authorization: Bearer $cf_token" \
          -H "Content-Type: application/json" \
          --data "{\"content\":\"$CF_NODE_ADDRESS\",\"ttl\":$CF_TTL}" \
          "https://api.cloudflare.com/client/v4/zones/''${CF_ZONE_ID}/dns_records/''${record_id}")

        if echo "$patch_resp" | jq -e '.success == true' >/dev/null 2>&1; then
          log "  DNS: updated — $CF_RECORD_NAME -> $CF_NODE_ADDRESS"
        else
          log "  DNS ERROR: PATCH failed: $(echo "$patch_resp" | jq -c '.errors')"
          return 1
        fi
      }

      promote() {
        log "==> Acquired leadership — promoting this node to primary."

        log "  Step 1/4: Restore headscale DB from litestream replica store..."
        systemctl start litestream-restore.service || {
          log "  WARNING: litestream-restore failed (proceeding — may be first boot)."
        }

        log "  Step 2/4: Starting headscale..."
        systemctl start headscale.service

        log "  Step 3/4: Starting litestream continuous replication..."
        systemctl start litestream-replicate.service

        log "  Step 4/4: Updating Cloudflare DNS record..."
        update_dns || log "  WARNING: DNS update failed — clients may use stale record until TTL expires."

        log "==> Promotion complete."
      }

      demote() {
        log "==> Lost leadership — demoting this node to standby."

        log "  Step 1/2: Stopping litestream replication..."
        systemctl stop litestream-replicate.service || true

        log "  Step 2/2: Stopping headscale..."
        systemctl stop headscale.service || true

        log "==> Demotion complete."
      }

      # Wait for the leader-election service to be up before polling.
      wait_for_leader_election
      log "Waiting ${toString cfg.startupGrace}s startup grace period..."
      sleep "$STARTUP_GRACE"

      log "Entering watchdog loop (poll every ''${POLL_INTERVAL}s)."

      while true; do
        # Fetch status, tolerate transient failures.
        STATUS=$(curl -sf --max-time 3 "$LEADER_URL" 2>/dev/null || echo "")

        if [ -z "$STATUS" ]; then
          log "WARNING: Could not reach leader-election daemon — skipping tick."
          sleep "$POLL_INTERVAL"
          continue
        fi

        IS_LEADER=$(echo "$STATUS" | jq -r '.isLeader // false')
        LEADER_ID=$(echo "$STATUS" | jq -r '.leaderId // "unknown"')

        if [ "$IS_LEADER" = "true" ] && [ "$IS_LEADER_PREV" != "true" ]; then
          promote
        elif [ "$IS_LEADER" = "false" ] && [ "$IS_LEADER_PREV" = "true" ]; then
          demote
        elif [ "$IS_LEADER" = "false" ] && [ "$IS_LEADER_PREV" = "" ]; then
          # First tick on a standby — make sure headscale is stopped.
          log "First tick: this node is standby (leader: $LEADER_ID). Ensuring headscale is stopped."
          systemctl is-active --quiet headscale.service && systemctl stop headscale.service || true
        fi

        IS_LEADER_PREV="$IS_LEADER"
        sleep "$POLL_INTERVAL"
      done
    '';
  };
in {
  # ---------------------------------------------------------------------------
  # Options
  # ---------------------------------------------------------------------------
  options.services.headscaleWatchdog = {
    enable = mkEnableOption "headscale leadership watchdog";

    leaderElectionBaseUrl = mkOption {
      type = types.str;
      default = "http://127.0.0.1:50555";
      description = "Base URL of the local leader-election daemon.";
    };

    pollInterval = mkOption {
      type = types.int;
      default = 5;
      description = "Seconds between leadership polls.";
    };

    startupGrace = mkOption {
      type = types.int;
      default = 5;
      description = ''
        Seconds to wait after the leader-election daemon reports healthy
        before the watchdog starts making decisions.  Gives the cluster time
        to converge on a leader after a node boot.
      '';
    };

    # ── Cloudflare DNS failover ─────────────────────────────────────────────
    cloudflare = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          When true, the watchdog calls the Cloudflare v4 API to update the
          headscale DNS A record to this node's IP every time this node is
          promoted to primary.

          Combined with a low TTL (60 s) this means Tailscale clients that
          reconnect after a failover will resolve the new primary within one
          TTL period — even clients that bypass Caddy entirely.

          The API token is never written to the Nix store; it is read from
          <option>tokenFile</option> at runtime.
        '';
      };

      tokenFile = mkOption {
        type = types.path;
        description = ''
          Path to a secrets file in systemd EnvironmentFile format:

            CLOUDFLARE_DNS_API_TOKEN=cfxxxxxxxxxxxxxxxx

          The headscale-watchdog system user must be able to read this file.
          When using sops-nix set <literal>owner = "headscale-watchdog"</literal>
          on the secret.  You can reuse the same token file as
          <option>services.caddyHeadscale.cloudflare.tokenFile</option>; if you
          do, make the caddy user part of the headscale-watchdog group so both
          services can read a single file.
        '';
        example = "/run/secrets/caddy-cloudflare-token";
      };

      zoneId = mkOption {
        type = types.str;
        description = ''
          Cloudflare Zone ID that contains the headscale A record.
          Visible on the domain's Overview page in the Cloudflare dashboard.
        '';
        example = "b6558c4a7b3b0a1c62d5f8e9d0f12345";
      };

      recordName = mkOption {
        type = types.str;
        description = ''
          Fully-qualified name of the DNS A record to update on promotion,
          e.g. <literal>headscale.example.com</literal>.
        '';
        example = "headscale.example.com";
      };

      nodeAddress = mkOption {
        type = types.str;
        description = ''
          Public IPv4 address of this node.  Written as the A record content
          when this node is promoted to primary.
        '';
        example = "203.0.113.11";
      };

      ttl = mkOption {
        type = types.int;
        default = 60;
        description = ''
          DNS record TTL in seconds.  60 is the Cloudflare minimum for
          non-proxied records and gives fast failover visibility.
        '';
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Implementation
  # ---------------------------------------------------------------------------
  config = mkIf cfg.enable {
    assertions = lib.optional cfgCf.enable {
      assertion = cfgCf.zoneId != "" && cfgCf.recordName != "" && cfgCf.nodeAddress != "";
      message = "services.headscaleWatchdog.cloudflare: zoneId, recordName, and nodeAddress must all be set when cloudflare.enable = true.";
    };

    # The watchdog starts/stops headscale and litestream system services, so it
    # must run as root.  It retains ProtectSystem=strict (read-only fs) and
    # other namespacing to limit blast radius.

    systemd.services.headscale-watchdog = {
      description = "Headscale leadership watchdog";
      wantedBy = ["multi-user.target"];
      after = [
        "network-online.target"
        "headscale-leader-election.service"
      ];
      wants = [
        "network-online.target"
        "headscale-leader-election.service"
      ];

      # The watchdog must NOT start headscale on activation — it will do so
      # only once it has confirmed leadership.
      serviceConfig = {
        Type = "simple";
        ExecStart = "${watchdogScript}/bin/headscale-watchdog";
        Restart = "on-failure";
        RestartSec = "5s";
        StandardOutput = "journal";
        StandardError = "journal";

        # Light hardening — keep filesystem mostly read-only; the watchdog
        # uses systemctl (over D-Bus) to manage services and only needs to
        # read the optional Cloudflare token file.
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        # Explicitly allow read access to the Cloudflare token file.
        ReadOnlyPaths = lib.optional cfgCf.enable cfgCf.tokenFile;
      };
    };

    # Ensure headscale does NOT start automatically — the watchdog owns it.
    # (headscale.service is installed by services.headscale.enable but we
    # remove it from the default target here.)
    systemd.services.headscale = {
      wantedBy = lib.mkForce [];
      # Allow the watchdog to start it without a dependency cycle.
      unitConfig.RefuseManualStop = lib.mkForce false;
    };
  };
}
