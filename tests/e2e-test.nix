# tests/e2e-test.nix
#
# End-to-end integration test for the headscale-ha NixOS stack.
#
# What is tested
# ──────────────
# Phase 0  Bootstrapping: Garage starts, all three leader-election daemons
#          connect to each other and converge on node1 as the initial leader.
# Phase 1  Nominal state: node1 leads, headscale starts, Caddy routes traffic
#          through the leader, and test data (a headscale user) is created.
# Phase 2  Failover: node1's leader-election service is stopped; within
#          ≤8 s node2 is elected; headscale restores from Garage and starts;
#          the test user created on node1 is still present after restore.
# Phase 3  Recovery: node1 restarts; because it has priority 10 vs node2's 20
#          it reclaims leadership; headscale moves back to node1.
# Phase 4  Quorum safety: both node2 and node3 stop; node1 is alone (1/3),
#          which is below the majority quorum of 2; it must step down.
# Phase 5  Quorum restore: node2 comes back; quorum = 2/3 is satisfied again;
#          node1 is re-elected.
# Phase 6  Client connectivity: two Tailscale clients register via headscale
#          and successfully exchange ICMP traffic through the WireGuard tunnel
#          (routed via the embedded DERP server).
# Phase 7  Failover with live clients: node1 goes down mid-session; node2 takes
#          over; client Tailscale IPs are identical after the DB restore;
#          cross-ping succeeds again; Caddy reroutes (end-to-end from a client).
# Phase 8  Storage outage: Garage is stopped while node2 is the primary;
#          headscale continues serving from local SQLite; VPN traffic flows;
#          new headscale data is written locally; Garage restarts and
#          litestream resumes replication (S3 object count increases).
#
# Infrastructure
# ──────────────
# • 4 QEMU VMs on VLAN 1 (192.168.1.0/24).
# • storage (192.168.1.90): Garage (AGPL S3-compatible object store).
# • node1/2/3 (192.168.1.11/12/13): the actual headscale-ha nodes.
# • mTLS cluster PKI is generated as a Nix derivation (openssl runCommand);
#   no external CA or secret store is required for the test itself.
# • Caddy runs with `tls internal` (Caddy's built-in CA) so no ACME is needed.
# • The leaderElection timeouts are shortened (deadThreshold 4 s, heartbeat 1 s)
#   so the test converges quickly.
#
# Running
# ───────
#   nix build .#checks.x86_64-linux.e2e -L
#
# Or via the runner that also handles optional real-credential injection:
#   ./tests/run-e2e.sh
{
  pkgs,
  lib,
  overlay,
  nixosModules,
}: let
  # ── 1. Cluster PKI (generated fresh, stored only in the Nix sandbox) ────
  #
  # Each cert carries both an IP SAN and a DNS SAN so connections work
  # regardless of whether the peer URL uses a hostname or a bare IP.
  clusterPKI =
    pkgs.runCommand "e2e-cluster-pki" {
      nativeBuildInputs = [pkgs.openssl];
    } ''
      set -euo pipefail
      mkdir -p "$out"

      # ── Cluster CA (2048-bit: fast to generate, fine for ephemeral CI) ──
      openssl genrsa -out "$out/ca.key" 2048 2>/dev/null
      openssl req -new -x509 \
        -key   "$out/ca.key" \
        -out   "$out/ca.crt" \
        -days  3 \
        -subj  "/O=headscale-ha-test/CN=e2e-cluster-ca" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

      # ── Per-node cert helper ─────────────────────────────────────────────
      gen_cert() {
        local name="$1" ip="$2"
        openssl genrsa -out "$out/$name.key" 2048 2>/dev/null
        openssl req -new \
          -key  "$out/$name.key" \
          -out  "$out/$name.csr" \
          -subj "/O=headscale-ha-test/CN=$name"
        openssl x509 -req \
          -in       "$out/$name.csr" \
          -CA       "$out/ca.crt" \
          -CAkey    "$out/ca.key" \
          -CAcreateserial \
          -out      "$out/$name.crt" \
          -days     3 \
          -extfile  <(printf 'subjectAltName=IP:%s,DNS:%s\nextendedKeyUsage=serverAuth,clientAuth\n' "$ip" "$name")
        rm "$out/$name.csr"
      }

      gen_cert node1 192.168.1.11
      gen_cert node2 192.168.1.12
      gen_cert node3 192.168.1.13

      # TLS cert for headscale.test.internal (SANs: all three node IPs + the
      # hostname, so Caddy can serve it and clients can verify CN/SAN)
      openssl genrsa -out "$out/headscale.key" 2048 2>/dev/null
      openssl req -new \
        -key  "$out/headscale.key" \
        -out  "$out/headscale.csr" \
        -subj "/O=headscale-ha-test/CN=headscale.test.internal"
      openssl x509 -req \
        -in       "$out/headscale.csr" \
        -CA       "$out/ca.crt" \
        -CAkey    "$out/ca.key" \
        -CAcreateserial \
        -out      "$out/headscale.crt" \
        -days     3 \
        -extfile  <(printf 'subjectAltName=DNS:headscale.test.internal,IP:192.168.1.11,IP:192.168.1.12,IP:192.168.1.13\nextendedKeyUsage=serverAuth\n')
      rm "$out/headscale.csr"

      # Quick sanity check — fail the build early if anything is wrong
      for n in node1 node2 node3 headscale; do
        openssl verify -CAfile "$out/ca.crt" "$out/$n.crt" >/dev/null
      done
    '';

  # ── 2. Common /etc/hosts — all VMs share the same host entries ─────────
  # NOTE: Garage S3 credentials are generated dynamically at VM startup by
  #       the garage-init.service on the storage node.  The test driver reads
  #       them from /run/garage-init/litestream.env and writes them to
  #       /run/garage/litestream.env on each HA node (Phase 0).
  sharedHosts = ''
    192.168.1.11  node1  headscale.test.internal
    192.168.1.12  node2
    192.168.1.13  node3
    192.168.1.90  storage
    192.168.1.101 client1
    192.168.1.102 client2
  '';

  # ── 3. Node factory — returns a NixOS module for a headscale-ha node ──
  #
  # All cluster-wide settings (PKI paths, litestream bucket, Caddy nodes,
  # Cloudflare-disabled watchdog) live here; only identity/priority differ.
  makeNode = {
    nodeName,
    priority,
    peerNodes,
    address,
  }: {
    config,
    lib,
    pkgs,
    ...
  }: let
    peerURLs = map (n: "https://${n}:50556") peerNodes;
  in {
    imports = [nixosModules.headscale-ha];
    nixpkgs.overlays = [overlay];

    # Static IP on the nixosTest VLAN-1 interface.
    # nixosTest assigns VLAN interfaces as eth1 (the second NIC; eth0 is the
    # test-driver management NIC).  If your kernel/qemu version uses a
    # different predictable name (e.g. ens4), adjust accordingly.
    networking.useDHCP = lib.mkForce false;
    networking.interfaces.eth1 = {
      useDHCP = false;
      ipv4.addresses = [
        {
          inherit address;
          prefixLength = 24;
        }
      ];
    };
    networking.defaultGateway = "192.168.1.1";
    networking.extraHosts = sharedHosts;

    services.headscaleHa = {
      enable = true;

      node = {
        id = nodeName;
        inherit priority;
        peers = peerURLs;
        leaderElectionPort = 50555;
        openLeaderElectionFirewall = true;

        tls = {
          caFile = "${clusterPKI}/ca.crt";
          certFile = "${clusterPKI}/${nodeName}.crt";
          keyFile = "${clusterPKI}/${nodeName}.key";
          listenAddr = ":50556";
        };
      };

      litestream = {
        # Credentials are written at runtime by the test driver (Phase 0)
        # after garage-init.service generates the Garage S3 key.
        credentialsFile = "/run/garage/litestream.env";
        replica = {
          type = "s3";
          bucket = "headscale-test";
          path = "db";
          endpoint = "http://storage:9000";
          region = "us-east-1"; # Garage ignores region, just needs a value
        };
      };

      headscale.settings = {
        server_url = "https://headscale.test.internal";
        listen_addr = "0.0.0.0:8080";
        grpc_listen_addr = "0.0.0.0:50443";
        metrics_listen_addr = "127.0.0.1:9090";
        log.level = "debug";
        prefixes = {
          v4 = "100.64.0.0/10";
          v6 = "fd7a:115c:a1e0::/48";
          allocation = "sequential";
        };
        dns = {
          magic_dns = true;
          base_domain = "ts.test.internal";
          nameservers.global = ["1.1.1.1"];
        };
        # In the offline test VM there is no internet access, so we must not
        # attempt to fetch the DERP map from controlplane.tailscale.com.
        # Use headscale's built-in DERP server instead.
        derp = {
          server = {
            enabled = true;
            region_id = 999;
            region_code = "headscale";
            region_name = "Headscale Embedded DERP";
            stun_listen_addr = "0.0.0.0:3478";
          };
          urls = []; # do NOT fetch from Tailscale
          auto_update_enabled = false;
        };
      };

      caddy = {
        enable = true;
        serverName = "headscale.test.internal";
        acmeEmail = "";
        # Use the shared cluster PKI cert so clients can verify TLS without
        # dealing with Caddy's runtime-generated internal CA.
        tls.extraConfig = "tls ${clusterPKI}/headscale.crt ${clusterPKI}/headscale.key";

        cloudflare.enable = false; # test uses internal TLS + local Garage

        nodes = [
          {
            address = "192.168.1.11";
            httpPort = 8080;
            grpcPort = 50443;
          }
          {
            address = "192.168.1.12";
            httpPort = 8080;
            grpcPort = 50443;
          }
          {
            address = "192.168.1.13";
            httpPort = 8080;
            grpcPort = 50443;
          }
        ];
      };

      # DNS failover disabled for the test (no Cloudflare credentials)
      watchdog = {
        pollInterval = 2;
        # Longer grace period: gives the test driver time to distribute
        # Garage credentials to /run/garage/litestream.env before the
        # watchdog's first promotion attempt runs litestream-restore.
        startupGrace = 15;
        dns.enable = false;
      };
    };

    # Shorten election timeouts so failover completes within ~8 s
    # (heartbeat 1 s, dead after 4 s without response, HTTP timeout 1 s)
    services.headscaleLeaderElection = {
      heartbeatInterval = "1s";
      deadThreshold = "4s";
      httpTimeout = "1s";
    };

    # Add headscale CLI (already included by services.headscale; this
    # ensures it's on PATH in test assertions too)
    environment.systemPackages = [pkgs.headscale pkgs.curl pkgs.jq];

    # Trust the cluster CA so tailscale (on client VMs) can verify the
    # headscale TLS cert without extra --accept-risk flags.
    security.pki.certificateFiles = ["${clusterPKI}/ca.crt"];

    # Open STUN (UDP 3478) and DERP (TCP 443 already open via Caddy)
    networking.firewall.allowedUDPPorts = [3478];

    virtualisation.memorySize = 768;
    virtualisation.cores = 2;

    # nixosTest needs these to build quickly
    virtualisation.diskSize = 4096; # 4 GiB
  };
in
  pkgs.testers.nixosTest {
    name = "headscale-ha-e2e";

    nodes = {
      # ── Garage storage node (always up; never participates in HA) ────────
      storage = {
        pkgs,
        lib,
        ...
      }: {
        networking.useDHCP = lib.mkForce false;
        networking.interfaces.eth1 = {
          useDHCP = false;
          ipv4.addresses = [
            {
              address = "192.168.1.90";
              prefixLength = 24;
            }
          ];
        };
        networking.defaultGateway = "192.168.1.1";
        networking.extraHosts = sharedHosts;

        # Garage — AGPL S3-compatible object storage (replaces MinIO)
        services.garage = {
          enable = true;
          package = pkgs.garage;
          settings = {
            metadata_dir = "/var/lib/garage/meta";
            data_dir = "/var/lib/garage/data";
            db_engine = "sqlite";
            replication_factor = 1;
            rpc_bind_addr = "[::]:3901";
            # rpc_public_addr must be reachable by other nodes (single-node here)
            rpc_public_addr = "192.168.1.90:3901";
            # Fixed secret for single-node test; change per cluster in production
            rpc_secret = "0000000000000000000000000000000000000000000000000000000000000001";
            s3_api = {
              s3_region = "us-east-1";
              api_bind_addr = "[::]:9000"; # matches litestream endpoint port
            };
            admin = {
              api_bind_addr = "[::]:3903";
              # Static token — acceptable for an ephemeral test node
              admin_token = "test-garage-admin";
            };
          };
        };

        # One-shot service: apply cluster layout, create bucket + key,
        # write credentials to /run/garage-init/litestream.env for the
        # test driver to read and distribute to HA nodes.
        systemd.services.garage-init = {
          description = "Initialize Garage layout, bucket, and litestream key";
          after = ["garage.service"];
          requires = ["garage.service"];
          wantedBy = ["multi-user.target"];
          path = [pkgs.curl pkgs.jq pkgs.coreutils];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            ADMIN_URL="http://127.0.0.1:3903"
            AUTH="Authorization: Bearer test-garage-admin"

            # Wait for the admin API to authenticate successfully.
            # GET /v1/status needs auth; becoming reachable means the server is up.
            echo "Waiting for Garage admin API..."
            until curl -sf -H "$AUTH" "$ADMIN_URL/v1/status" >/dev/null; do sleep 1; done
            echo "Garage admin API is up."

            # Get the local node ID from the status JSON
            NODE_ID=$(curl -sf -H "$AUTH" "$ADMIN_URL/v1/status" | jq -r '.node')
            echo "Node ID: $NODE_ID"

            # Apply single-node layout (zone dc1, capacity 100 MB = 100 000 000 bytes)
            curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' \
              --data "[{\"id\":\"$NODE_ID\",\"zone\":\"dc1\",\"capacity\":100000000,\"tags\":[]}]" \
              "$ADMIN_URL/v1/layout" >/dev/null
            curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' \
              --data '{"version":1}' \
              "$ADMIN_URL/v1/layout/apply" >/dev/null
            echo "Layout applied."

            # Create the headscale-test bucket
            BUCKET_ID=$(curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' \
              --data '{"globalAlias":"headscale-test"}' \
              "$ADMIN_URL/v1/bucket" | jq -r '.id')
            echo "Bucket created: $BUCKET_ID"

            # Create litestream key — POST /v1/key?list returns accessKeyId + secretAccessKey
            KEY_JSON=$(curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' \
              --data '{"name":"litestream-key"}' \
              "$ADMIN_URL/v1/key?list")
            KEY_ID=$(printf '%s' "$KEY_JSON" | jq -r '.accessKeyId')
            SECRET=$(printf '%s' "$KEY_JSON" | jq -r '.secretAccessKey')
            echo "Key created: $KEY_ID"

            # Grant read/write/owner access on the bucket
            curl -sf -X POST -H "$AUTH" -H 'Content-Type: application/json' \
              --data "{\"bucketId\":\"$BUCKET_ID\",\"accessKeyId\":\"$KEY_ID\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":true}}" \
              "$ADMIN_URL/v1/bucket/allow" >/dev/null
            echo "Bucket permissions set."

            # Persist credentials for the test driver to distribute to HA nodes
            mkdir -p /run/garage-init
            printf 'LITESTREAM_ACCESS_KEY_ID=%s\nLITESTREAM_SECRET_ACCESS_KEY=%s\n' \
              "$KEY_ID" "$SECRET" > /run/garage-init/litestream.env
            echo "Garage init complete — bucket headscale-test ready."
          '';
        };

        # curl + jq needed by the test driver assertions (phase1d)
        environment.systemPackages = [pkgs.curl pkgs.jq];

        networking.firewall.allowedTCPPorts = [9000];
        virtualisation.memorySize = 384;
        virtualisation.cores = 1;
      };

      # ── HA nodes ─────────────────────────────────────────────────────────
      node1 = makeNode {
        nodeName = "node1";
        priority = 10;
        peerNodes = ["node2" "node3"];
        address = "192.168.1.11";
      };

      node2 = makeNode {
        nodeName = "node2";
        priority = 20;
        peerNodes = ["node1" "node3"];
        address = "192.168.1.12";
      };

      node3 = makeNode {
        nodeName = "node3";
        priority = 30;
        peerNodes = ["node1" "node2"];
        address = "192.168.1.13";
      };

      # ── Tailscale client VMs (for phase 6 connectivity test) ─────────────
      client1 = {
        pkgs,
        lib,
        ...
      }: {
        networking.useDHCP = lib.mkForce false;
        networking.interfaces.eth1 = {
          useDHCP = false;
          ipv4.addresses = [
            {
              address = "192.168.1.101";
              prefixLength = 24;
            }
          ];
        };
        networking.defaultGateway = "192.168.1.1";
        networking.extraHosts = sharedHosts;

        # Trust the cluster CA so tailscale can verify headscale's TLS cert.
        security.pki.certificateFiles = ["${clusterPKI}/ca.crt"];

        services.tailscale.enable = true;
        # Allow tailscale's tun device through the firewall.
        networking.firewall.checkReversePath = "loose";
        networking.firewall.trustedInterfaces = ["tailscale0"];

        environment.systemPackages = [pkgs.tailscale pkgs.curl];
        virtualisation.memorySize = 256;
        virtualisation.cores = 1;
      };

      client2 = {
        pkgs,
        lib,
        ...
      }: {
        networking.useDHCP = lib.mkForce false;
        networking.interfaces.eth1 = {
          useDHCP = false;
          ipv4.addresses = [
            {
              address = "192.168.1.102";
              prefixLength = 24;
            }
          ];
        };
        networking.defaultGateway = "192.168.1.1";
        networking.extraHosts = sharedHosts;

        security.pki.certificateFiles = ["${clusterPKI}/ca.crt"];

        services.tailscale.enable = true;
        networking.firewall.checkReversePath = "loose";
        networking.firewall.trustedInterfaces = ["tailscale0"];

        environment.systemPackages = [pkgs.tailscale pkgs.curl];
        virtualisation.memorySize = 256;
        virtualisation.cores = 1;
      };
    };

    testScript = ''
      import json
      import sys

      # ── Helper functions ─────────────────────────────────────────────────────

      def status(machine):
          """Return the parsed /status JSON from a node's leader-election daemon."""
          raw = machine.succeed("curl -sf http://127.0.0.1:50555/status")
          return json.loads(raw)

      def wait_for_leader(machine, expected_id, timeout=30):
          """Block until `machine` reports `expected_id` as leader with quorum."""
          machine.wait_until_succeeds(
              "curl -sf http://127.0.0.1:50555/status "
              f"| jq -e '.leaderId == \"{expected_id}\" and .hasQuorum'",
              timeout=timeout,
          )

      def assert_is_leader(machine):
          """/leader must return HTTP 200 (used by Caddy health checks)."""
          machine.succeed("curl -sf http://127.0.0.1:50555/leader")

      def assert_not_leader(machine):
          """/leader must return HTTP 503."""
          machine.fail("curl -sf http://127.0.0.1:50555/leader")

      def headscale_socket_cmd(machine, cmd):
          """Run a headscale CLI command via the unix socket."""
          return machine.succeed(
              f"headscale {cmd} --output json 2>/dev/null || "
              f"headscale {cmd} 2>/dev/null"
          )

      # ── Phase 0: Infrastructure bootstrapping ───────────────────────────────

      with subtest("phase0: start all VMs and wait for Garage + election daemons"):
          start_all()

          storage.wait_for_unit("garage.service")
          storage.wait_for_unit("garage-init.service")

          # Distribute Garage S3 credentials to each HA node.
          # garage-init writes dynamic key/secret to /run/garage-init/litestream.env;
          # we push them to /run/garage/litestream.env which is the EnvironmentFile
          # litestream-replicate and litestream-restore read at start time.
          access_key = storage.succeed(
              "awk -F= '/LITESTREAM_ACCESS_KEY_ID/{print $2}' /run/garage-init/litestream.env"
          ).strip()
          secret_key = storage.succeed(
              "awk -F= '/LITESTREAM_SECRET_ACCESS_KEY/{print $2}' /run/garage-init/litestream.env"
          ).strip()
          for machine in [node1, node2, node3]:
              machine.succeed("mkdir -p /run/garage")
              machine.succeed(f"printf 'LITESTREAM_ACCESS_KEY_ID=%s\\nLITESTREAM_SECRET_ACCESS_KEY=%s\\n' '{access_key}' '{secret_key}' > /run/garage/litestream.env")

          for m in [node1, node2, node3]:
              m.wait_for_unit("headscale-leader-election.service")
              m.wait_for_open_port(50555)   # plain HTTP
              m.wait_for_open_port(50556)   # mTLS gossip

      # ── Phase 1: Initial election — node1 (priority 10) must lead ───────────

      with subtest("phase1: node1 elected as initial leader"):
          # Allow up to 20 s for all three nodes to converge
          wait_for_leader(node1, "node1", timeout=20)
          wait_for_leader(node2, "node1", timeout=20)
          wait_for_leader(node3, "node1", timeout=20)

          assert_is_leader(node1)
          assert_not_leader(node2)
          assert_not_leader(node3)

          # Sanity-check quorum fields
          st = status(node1)
          assert st["totalNodes"] == 3, f"expected 3 nodes, got {st['totalNodes']}"
          assert st["quorum"]     == 2, f"expected quorum 2, got {st['quorum']}"
          assert st["healthyNodes"] == 3, f"expected 3 healthy, got {st['healthyNodes']}"

      with subtest("phase1b: watchdog promotes headscale on node1"):
          # headscale is started by the watchdog after the grace period —
          # use wait_until_succeeds so NixOS doesn't give up at system-settled.
          node1.wait_until_succeeds("systemctl is-active headscale.service", timeout=60)
          node1.wait_for_open_port(8080)
          node1.succeed("curl -sf http://127.0.0.1:8080/health")

      with subtest("phase1c: create test data on node1"):
          # Create a user so we can verify data continuity after failover
          node1.succeed("headscale users create e2e-test-user")
          node1.succeed("headscale users list | grep e2e-test-user")

      with subtest("phase1d: litestream is replicating to Garage"):
          # litestream-replicate is also watchdog-managed — use wait_until_succeeds
          node1.wait_until_succeeds("systemctl is-active litestream-replicate.service", timeout=60)
          # Give litestream a few seconds to push the initial snapshot
          import time; time.sleep(5)
          # Verify at least one object was written — poll the Garage admin API
          storage.wait_until_succeeds(
              "curl -sf -H 'Authorization: Bearer test-garage-admin' "
              "'http://127.0.0.1:3903/v1/bucket?globalAlias=headscale-test' "
              "| jq -e '.objects > 0'",
              timeout=30,
          )

      with subtest("phase1e: Caddy is routing through node1 (active health check)"):
          node1.wait_for_unit("caddy.service")
          # /leader returns 200 on node1; Caddy's health check probes this
          node1.succeed("curl -sf http://127.0.0.1:50555/leader")
          # Caddy serves the virtual host 'headscale.test.internal'; connecting by
          # raw IP would miss the SNI/Host → use --resolve to alias the hostname to
          # the local interface while still sending the correct TLS SNI.
          node1.succeed(
              "curl -sfk --resolve 'headscale.test.internal:443:127.0.0.1'"
              " https://headscale.test.internal/health"
          )

      # ── Phase 2: Failover — stop node1, node2 should take over ──────────────

      with subtest("phase2: stop node1 leader-election → node2 takes over"):
          node1.systemctl("stop headscale-leader-election.service")

          # Dead threshold = 4 s + one election cycle ≈ 6-8 s
          wait_for_leader(node2, "node2", timeout=20)
          wait_for_leader(node3, "node2", timeout=20)

          assert_is_leader(node2)
          assert_not_leader(node3)

      with subtest("phase2b: headscale starts on node2 after litestream restore"):
          node2.wait_until_succeeds("systemctl is-active headscale.service", timeout=90)
          node2.wait_for_open_port(8080)
          node2.succeed("curl -sf http://127.0.0.1:8080/health")

      with subtest("phase2c: data continuity — test user present after restore"):
          # The user created on node1 must be present in the DB restored from Garage
          node2.succeed("headscale users list | grep e2e-test-user")

      # ── Phase 3: Recovery — node1 restarts and reclaims leadership ──────────

      with subtest("phase3: node1 restarts and reclaims leadership (priority 10 < 20)"):
          node1.systemctl("start headscale-leader-election.service")
          node1.wait_for_unit("headscale-leader-election.service")
          node1.wait_for_open_port(50555)
          node1.wait_for_open_port(50556)

          # Priority 10 < priority 20: node1 should outbid node2
          wait_for_leader(node1, "node1", timeout=30)
          wait_for_leader(node2, "node1", timeout=30)
          wait_for_leader(node3, "node1", timeout=30)

          assert_is_leader(node1)
          assert_not_leader(node2)

      with subtest("phase3b: headscale is back on node1 after recovery restore"):
          node1.wait_until_succeeds("systemctl is-active headscale.service", timeout=90)
          node1.wait_for_open_port(8080)
          node1.succeed("curl -sf http://127.0.0.1:8080/health")
          # Data must still be there after the second restore cycle
          node1.succeed("headscale users list | grep e2e-test-user")

      # ── Phase 4: Quorum safety — minority partition must not elect ───────────

      with subtest("phase4: stop node2+node3 → node1 alone, below quorum (1/3 < 2)"):
          node2.systemctl("stop headscale-leader-election.service")
          node3.systemctl("stop headscale-leader-election.service")

          # node1 should detect it has only 1/3 healthy nodes (< quorum 2)
          # and step down.  Allow up to 15 s (deadThreshold 4 s + buffer).
          node1.wait_until_succeeds(
              "curl -sf http://127.0.0.1:50555/status"
              " | jq -e '.isLeader and .hasQuorum | not'",
              timeout=15,
          )
          # /leader must return 503 (neither leader nor asserts quorum)
          node1.fail("curl -sf http://127.0.0.1:50555/leader")

      # ── Phase 5: Quorum restore ──────────────────────────────────────────────

      with subtest("phase5: node2 returns → quorum 2/3 satisfied → node1 re-elected"):
          node2.systemctl("start headscale-leader-election.service")
          node2.wait_for_unit("headscale-leader-election.service")
          node2.wait_for_open_port(50555)

          wait_for_leader(node1, "node1", timeout=30)
          wait_for_leader(node2, "node1", timeout=30)

          assert_is_leader(node1)
          assert_not_leader(node2)

          st = status(node1)
          assert st["hasQuorum"],     "node1 should report hasQuorum=true"
          assert st["healthyNodes"] >= 2, f"expected ≥2 healthy nodes, got {st['healthyNodes']}"

      # ── Phase 6: Tailscale client connectivity ──────────────────────────────

      with subtest("phase6: register two Tailscale clients and ping each other"):
          # headscale is running on node1 (restored after phase3b).
          # Look up the numeric user ID (headscale 0.28 --user takes uint).
          # The CLI marshals GetUsers() directly → flat JSON array.
          uid = node1.succeed(
              "headscale users list --output json"
              " | jq -r '.[] | select(.name == \"e2e-test-user\") | .id'"
          ).strip()
          assert uid, "could not find e2e-test-user in headscale users list"

          # Create a reusable pre-auth key for the test user.
          # The CLI passes GetPreAuthKey() directly → JSON has .key at top level.
          authkey = node1.succeed(
              f"headscale preauthkeys create "
              f"--user {uid} --reusable --expiration 10m "
              f"--output json | jq -r .key"
          ).strip()
          assert authkey, "failed to create pre-auth key"

          # Register both clients against headscale.
          # --accept-dns=false avoids needing to configure DNS resolvers in the test.
          for client in [client1, client2]:
              client.wait_for_unit("tailscaled.service")
              client.succeed(
                  f"tailscale up "
                  f"--login-server=https://headscale.test.internal "
                  f"--authkey={authkey} "
                  f"--accept-dns=false "
                  f"--accept-routes"
              )

          # Wait until both clients appear as connected in headscale.
          def wait_for_nodes(n):
              node1.wait_until_succeeds(
                  f"headscale nodes list --output json 2>/dev/null "
                  f"| jq -e '[.[] | select(.online)] | length >= {n}'",
                  timeout=60,
              )

          wait_for_nodes(2)

          # Retrieve each client's Tailscale IP (100.x.x.x range).
          ts_ip1 = client1.wait_until_succeeds(
              "tailscale ip -4 2>/dev/null | grep -v '^$'", timeout=30
          ).strip()
          ts_ip2 = client2.wait_until_succeeds(
              "tailscale ip -4 2>/dev/null | grep -v '^$'", timeout=30
          ).strip()

          assert ts_ip1.startswith("100."), f"unexpected Tailscale IP for client1: {ts_ip1}"
          assert ts_ip2.startswith("100."), f"unexpected Tailscale IP for client2: {ts_ip2}"

          # Cross-ping: each client pings the other three times.
          client1.wait_until_succeeds(f"ping -c3 -W5 {ts_ip2}", timeout=60)
          client2.wait_until_succeeds(f"ping -c3 -W5 {ts_ip1}", timeout=60)

      # ── Phase 7: Client connectivity survives a failover ──────────────────────

      with subtest("phase7: node1 fails again → node2 leads → Tailscale tunnel stays up"):
          # node3 is still stopped from phase 4 — bring it back first so that
          # stopping node1 leaves node2+node3 = 2/3 ≥ quorum (majority of 3).
          node3.systemctl("start headscale-leader-election.service")
          node3.wait_for_unit("headscale-leader-election.service")
          node3.wait_for_open_port(50555)

          # Stop node1; node2 (priority 20 < node3 priority 30) should win.
          node1.systemctl("stop headscale-leader-election.service")
          wait_for_leader(node2, "node2", timeout=20)
          wait_for_leader(node3, "node2", timeout=20)

          assert_is_leader(node2)
          assert_not_leader(node3)

      with subtest("phase7b: headscale on node2 and Tailscale IPs stable after restore"):
          node2.wait_until_succeeds("systemctl is-active headscale.service", timeout=90)
          node2.wait_for_open_port(8080)
          node2.succeed("curl -sf http://127.0.0.1:8080/health")

          # IPs must be identical — the DB was round-tripped through Garage.
          ts_ip1_after = client1.wait_until_succeeds(
              "tailscale ip -4 2>/dev/null | grep -v '^$'", timeout=30
          ).strip()
          ts_ip2_after = client2.wait_until_succeeds(
              "tailscale ip -4 2>/dev/null | grep -v '^$'", timeout=30
          ).strip()
          assert ts_ip1_after == ts_ip1, (
              f"client1 IP changed across failover: {ts_ip1} → {ts_ip1_after}"
          )
          assert ts_ip2_after == ts_ip2, (
              f"client2 IP changed across failover: {ts_ip2} → {ts_ip2_after}"
          )

          # WireGuard keys are cached locally from phase 6 so the tunnel stays
          # live even before tailscaled fully re-establishes the control-plane
          # long-poll to node2's headscale.  The cross-ping is the definitive
          # VPN-survivability assertion; it also exercises the DERP path on node2.
          client1.wait_until_succeeds(f"ping -c3 -W5 {ts_ip2}", timeout=90)
          client2.wait_until_succeeds(f"ping -c3 -W5 {ts_ip1}", timeout=90)

      with subtest("phase7c: Caddy reroutes to node2 — verified end-to-end from client"):
          # headscale.test.internal resolves to node1 (192.168.1.11).
          # node1's Caddy is still up; its active health check on /leader now
          # routes to node2 (the only backend returning 200).  This exercises
          # the full path: client → node1 Caddy → node2 headscale.
          client1.succeed("curl -sf https://headscale.test.internal/health")

      # ── Phase 8: Storage outage — headscale must keep serving ──────────────

      with subtest("phase8: stop Garage → headscale and VPN traffic unaffected"):
          # Baseline object count before the outage.
          objects_before = int(storage.succeed(
              "curl -sf -H 'Authorization: Bearer test-garage-admin'"
              " 'http://127.0.0.1:3903/v1/bucket?globalAlias=headscale-test'"
              " | jq '.objects'"
          ).strip())

          storage.systemctl("stop garage.service")
          import time; time.sleep(5)  # give litestream time to notice

          # headscale stores state in local SQLite — must stay healthy.
          node2.succeed("curl -sf http://127.0.0.1:8080/health")
          node2.succeed("systemctl is-active headscale.service")

          # Leader election is pure in-memory/mTLS — completely unaffected.
          assert_is_leader(node2)

          # Prove the local DB is writable even without a replication backend.
          node2.succeed("headscale users create storage-offline-user")

          # WireGuard is peer-to-peer — VPN traffic must continue flowing.
          client1.succeed(f"ping -c3 -W5 {ts_ip2}")
          client2.succeed(f"ping -c3 -W5 {ts_ip1}")

      with subtest("phase8b: Garage restores → litestream resumes replication"):
          storage.systemctl("start garage.service")
          storage.wait_for_unit("garage.service")
          storage.wait_for_open_port(9000)

          # litestream retries with backoff when the backend is unavailable;
          # wait for the service to report active again.
          node2.wait_until_succeeds(
              "systemctl is-active litestream-replicate.service", timeout=60
          )

          # After reconnecting, litestream flushes pending WAL frames.
          # The user created during the outage must have been replicated,
          # so the S3 object count must exceed the pre-outage baseline.
          storage.wait_until_succeeds(
              "curl -sf -H 'Authorization: Bearer test-garage-admin'"
              " 'http://127.0.0.1:3903/v1/bucket?globalAlias=headscale-test'"
              f" | jq -e '.objects > {objects_before}'",
              timeout=60,
          )

      print("All phases passed — headscale-ha e2e test complete.", file=sys.stderr)
    '';
  }
