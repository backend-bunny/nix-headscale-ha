# Quickstart — 3-node headscale HA cluster

This guide walks you through consuming `nix-headscale-ha` from **your own flake**
and deploying a three-node headscale cluster with automatic failover.

## How it works

```
                   ┌──────────────────────────────────┐
  Tailscale client │  headscale.example.com  (DNS A)  │
  ────────────────▶│  Caddy (every node)              │
                   │  health-checks /leader → primary │
                   └──────────┬──────────┬──────────┬─┘
                              │          │          │
                         node1 :8080  node2      node3
                         (primary)    (standby)  (standby)
                              │
                    litestream-replicate ──▶ S3 / Garage
                              │
               node2/3 litestream-restore on promotion
```

Each node runs:
- **leader-election** — Raft-like gossip over mTLS (`:50555`/`:50556`)
- **headscale-watchdog** — promotes/demotes headscale based on `/status`
- **litestream** — continuous replication to S3 on the primary; one-shot restore on promotion
- **Caddy** — terminates TLS, health-checks `/leader`, routes to primary only

---

## Prerequisites

| Requirement | Notes |
|---|---|
| NixOS hosts | x86_64-linux, kernel ≥ 5.15 |
| S3-compatible storage | AWS S3, Cloudflare R2, Garage, MinIO, … |
| Domain + DNS | Cloudflare recommended for DNS-01 TLS + failover A-record |
| Secrets manager | [sops-nix](https://github.com/Mic92/sops-nix) or [agenix](https://github.com/ryantm/agenix) |

---

## 1 — Reference the flake

In **your** repo's `flake.nix`, add `nix-headscale-ha` as an input:

```nix
{
  inputs = {
    nixpkgs.url       = "github:NixOS/nixpkgs/nixos-unstable";
    nix-headscale-ha  = {
      url   = "github:backend-bunny/nix-headscale-ha";
      # Pin nixpkgs to your own to avoid a second copy:
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nix-headscale-ha, ... }: {

    nixosConfigurations = let
      # Shared helper — reduces boilerplate in each node definition.
      mkNode = { hostname, nodeId, priority, selfAddress, peerAddresses, publicIp }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            # 1. Inject the overlay so pkgs.headscale-leader-election is available.
            { nixpkgs.overlays = [ nix-headscale-ha.overlay ]; }

            # 2. The top-level HA module (imports all sub-modules).
            nix-headscale-ha.nixosModules.headscale-ha

            # 3. Shared cluster config (same across all nodes).
            ./cluster-common.nix

            # 4. Per-node identity.
            {
              networking.hostName = hostname;
              networking.interfaces.eth0.ipv4.addresses = [{
                address      = selfAddress;
                prefixLength = 24;
              }];

              services.headscaleHa.node = {
                id       = nodeId;
                inherit priority;
                peers    = map (a: "https://${a}:50556") peerAddresses;
                openLeaderElectionFirewall = true;
                tls = {
                  caFile   = "/run/secrets/le-ca.crt";
                  certFile = "/run/secrets/le-${nodeId}.crt";
                  keyFile  = "/run/secrets/le-${nodeId}.key";
                };
              };

              services.headscaleHa.watchdog.dns.nodeAddress = publicIp;
            }
          ];
        };

      peers = {
        node1 = "192.168.1.11";
        node2 = "192.168.1.12";
        node3 = "192.168.1.13";
      };

    in {
      node1 = mkNode {
        hostname      = "headscale-node1";
        nodeId        = "node1";
        priority      = 10;          # lowest = preferred primary
        selfAddress   = peers.node1;
        peerAddresses = [ peers.node2 peers.node3 ];
        publicIp      = "203.0.113.11";
      };

      node2 = mkNode {
        hostname      = "headscale-node2";
        nodeId        = "node2";
        priority      = 20;
        selfAddress   = peers.node2;
        peerAddresses = [ peers.node1 peers.node3 ];
        publicIp      = "203.0.113.12";
      };

      node3 = mkNode {
        hostname      = "headscale-node3";
        nodeId        = "node3";
        priority      = 30;
        selfAddress   = peers.node3;
        peerAddresses = [ peers.node1 peers.node2 ];
        publicIp      = "203.0.113.13";
      };
    };
  };
}
```

---

## 2 — Shared cluster config (`cluster-common.nix`)

Everything that is **identical across all three nodes** lives here.

```nix
# cluster-common.nix
{ pkgs, ... }: {

  services.headscaleHa = {
    enable = true;

    # -- Litestream ----------------------------------------------------------
    # Both replicate and restore point at the same S3 bucket.
    # Only the primary ever runs litestream-replicate.
    litestream = {
      credentialsFile = "/run/secrets/litestream";   # see §4 below

      replica = {
        type         = "s3";
        bucket       = "my-headscale-ha";
        path         = "db";
        endpoint     = "";            # empty = AWS S3; set for Garage/R2/MinIO
        region       = "eu-west-1";
        retention    = "24h";
        syncInterval = "1s";
      };
    };

    # -- Headscale -----------------------------------------------------------
    headscale.settings = {
      server_url         = "https://headscale.example.com";
      listen_addr        = "0.0.0.0:8080";
      grpc_listen_addr   = "0.0.0.0:50443";
      metrics_listen_addr = "127.0.0.1:9090";
      log.level          = "info";

      prefixes = {
        v4         = "100.64.0.0/10";
        v6         = "fd7a:115c:a1e0::/48";
        allocation = "sequential";
      };

      dns = {
        magic_dns             = true;
        base_domain           = "ts.example.com";
        nameservers.global    = [ "1.1.1.1" ];
      };
    };

    # -- Caddy ---------------------------------------------------------------
    caddy = {
      enable      = true;
      serverName  = "headscale.example.com";
      acmeEmail   = "admin@example.com";

      # Cloudflare DNS-01 — no inbound port 80 required.
      cloudflare = {
        enable    = true;
        tokenFile = "/run/secrets/caddy-cloudflare-token";
      };

      # All three nodes are listed; Caddy's active health check routes to the
      # current primary only (the one returning 200 on /leader).
      nodes = [
        { address = "192.168.1.11"; httpPort = 8080; grpcPort = 50443; }
        { address = "192.168.1.12"; httpPort = 8080; grpcPort = 50443; }
        { address = "192.168.1.13"; httpPort = 8080; grpcPort = 50443; }
      ];
    };

    # -- Watchdog ------------------------------------------------------------
    watchdog = {
      pollInterval  = 5;
      startupGrace  = 8;

      # On promotion, update the DNS A record to point at this node.
      dns = {
        enable     = true;
        zoneId     = "b6558c4a7b3b0a1c62d5f8e9d0f12345";
        ttl        = 60;
        # nodeAddress is set per-node in flake.nix above
      };
    };
  };

  # -- Firewall --------------------------------------------------------------
  networking.firewall = {
    enable           = true;
    allowedTCPPorts  = [ 22 80 443 ];  # 50555/50556 opened by openLeaderElectionFirewall
    allowedUDPPorts  = [ 41641 ];      # Tailscale STUN
  };

  services.openssh = {
    enable                        = true;
    settings.PasswordAuthentication = false;
  };

  system.stateVersion = "24.11";
}
```

---

## 3 — Generate mTLS certificates

The leader-election daemons authenticate each other with mutual TLS.
Generate the cluster PKI **once** (store output in your secrets manager):

```bash
# From the nix-headscale-ha repo, or copy scripts/gen-cluster-certs.sh
bash scripts/gen-cluster-certs.sh node1 node2 node3
# Produces: ca.crt  node{1,2,3}.crt  node{1,2,3}.key
```

---

## 4 — Secrets

Each node needs these secrets at the paths referenced above:

| Path | Content | Owner |
|---|---|---|
| `/run/secrets/litestream` | `LITESTREAM_ACCESS_KEY_ID=…`<br>`LITESTREAM_SECRET_ACCESS_KEY=…` | `root` |
| `/run/secrets/caddy-cloudflare-token` | `CLOUDFLARE_DNS_API_TOKEN=cf…` | `caddy` |
| `/run/secrets/le-ca.crt` | Cluster CA certificate | `root` (0444) |
| `/run/secrets/le-nodeN.crt` | This node's TLS certificate | `root` (0444) |
| `/run/secrets/le-nodeN.key` | This node's TLS private key | `root` (0400) |

### Example with sops-nix

```nix
# In your per-node module or in cluster-common.nix
sops.secrets = {
  litestream = {
    sopsFile = ./secrets/cluster.yaml;
    owner    = "root";
    mode     = "0400";
    path     = "/run/secrets/litestream";
  };

  "caddy-cloudflare-token" = {
    sopsFile = ./secrets/cluster.yaml;
    owner    = "caddy";
    mode     = "0400";
    path     = "/run/secrets/caddy-cloudflare-token";
  };

  # CA cert is not sensitive — readable by all
  "le-ca.crt" = {
    sopsFile = ./secrets/cluster-ca.yaml;
    mode     = "0444";
    path     = "/run/secrets/le-ca.crt";
  };

  # Per-node certs/keys — add to each node's own secrets file
  "le-node1.crt" = {
    sopsFile = ./secrets/node1.yaml;
    mode     = "0444";
    path     = "/run/secrets/le-node1.crt";
  };
  "le-node1.key" = {
    sopsFile = ./secrets/node1.yaml;
    mode     = "0400";
    path     = "/run/secrets/le-node1.key";
  };
};
```

---

## 5 — Deploy

```bash
# First deploy (or use nixos-anywhere for bare-metal provisioning):
nixos-rebuild switch --flake .#node1 --target-host root@203.0.113.11
nixos-rebuild switch --flake .#node2 --target-host root@203.0.113.12
nixos-rebuild switch --flake .#node3 --target-host root@203.0.113.13
```

Nodes will elect a primary within ~5 seconds of booting.

---

## 6 — Verify

```bash
# Which node is currently primary?
curl -s http://192.168.1.11:50555/status | jq .
# { "nodeId": "node1", "isLeader": true, "hasQuorum": true, "healthyNodes": 3 }

# Headscale health (via Caddy)
curl -s https://headscale.example.com/health
# { "status": "pass" }

# Create a user and pre-auth key
ssh root@203.0.113.11 headscale users create my-org
ssh root@203.0.113.11 headscale preauthkeys create --user 1 --reusable --expiration 24h

# Test failover: kill the primary and watch node2 take over
ssh root@203.0.113.11 systemctl stop headscale-leader-election
curl -s http://192.168.1.12:50555/status | jq .isLeader   # → true
```

---

## Using Garage instead of AWS S3

Set the endpoint and force path-style in the litestream replica block:

```nix
litestream.replica = {
  type        = "s3";
  bucket      = "headscale-ha";
  path        = "db";
  endpoint    = "http://garage.internal:9000";
  region      = "garage";          # any non-empty string
  forcePathStyle = true;
  retention   = "24h";
  syncInterval = "1s";
};
```

---

## LAN / private deployment (no public domain)

Skip the Cloudflare blocks and use Caddy's internal CA instead:

```nix
services.headscaleHa.caddy = {
  enable     = true;
  serverName = "headscale.lan";
  acmeEmail  = "";                    # not needed for internal CA

  cloudflare.enable = false;

  # Caddy generates a self-signed CA trusted cluster-wide via NixOS PKI.
  tls.extraConfig = "tls internal";
};

# Distribute the internal CA to all clients:
security.pki.certificateFiles = [ "/run/secrets/caddy-internal-ca.crt" ];
```
