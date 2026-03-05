# nixos/node2.nix
#
# Example NixOS configuration for the second cluster node.
#
# This node has priority 20 (higher number = lower priority), so it acts as
# the standby replica and only becomes primary if node1 is unreachable.
#
# The headscale.settings block, caddy.nodes, and litestream config are
# intentionally identical to node1 — only the node identity block differs.
{
  config,
  pkgs,
  lib,
  ...
}: {
  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------
  networking.hostName = "headscale-node2";

  networking.interfaces.eth0.ipv4.addresses = [
    {
      address = "192.168.1.12";
      prefixLength = 24;
    }
  ];
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = ["1.1.1.1" "8.8.8.8"];

  # ---------------------------------------------------------------------------
  # Headscale HA stack
  # ---------------------------------------------------------------------------
  services.headscaleHa = {
    enable = true;

    # -- Node identity --------------------------------------------------------
    node = {
      id = "node2";
      priority = 20; # ← standby (higher number = lower priority)
      peers = [
        "https://192.168.1.11:50556" # node1 mTLS peer-gossip endpoint
        "https://192.168.1.13:50556" # node3 mTLS peer-gossip endpoint
      ];
      leaderElectionPort = 50555;
      openLeaderElectionFirewall = true;

      tls = {
        caFile = "/run/secrets/le-ca.crt";
        certFile = "/run/secrets/le-node2.crt";
        keyFile = "/run/secrets/le-node2.key";
      };
    };

    # -- Litestream -----------------------------------------------------------
    # Identical to node1 — both nodes read/write the same S3 bucket.
    # Only the primary node ever runs litestream-replicate; the replica uses
    # litestream-restore (one-shot) when it gets promoted.
    litestream = {
      credentialsFile = "/run/secrets/litestream";

      replica = {
        type = "s3";
        bucket = "my-headscale-ha";
        path = "db";
        endpoint = "";
        region = "eu-west-1";
        retention = "24h";
        syncInterval = "1s";
      };
    };

    # -- Headscale settings ---------------------------------------------------
    # Must be identical across all nodes so any node can serve clients after
    # restore.
    headscale.settings = {
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

      dns = {
        magic_dns = true;
        base_domain = "ts.example.com";
        nameservers.global = ["1.1.1.1"];
      };
    };

    # -- Caddy ----------------------------------------------------------------
    caddy = {
      enable = true;
      serverName = "headscale.example.com";
      acmeEmail = "admin@example.com";

      cloudflare = {
        enable = true;
        tokenFile = "/run/secrets/caddy-cloudflare-token";
      };

      nodes = [
        {
          address = "192.168.1.11";
          httpPort = 8080;
          grpcPort = 50443;
        } # node1
        {
          address = "192.168.1.12";
          httpPort = 8080;
          grpcPort = 50443;
        } # node2
        {
          address = "192.168.1.13";
          httpPort = 8080;
          grpcPort = 50443;
        } # node3
      ];
    };

    # -- Watchdog -------------------------------------------------------------
    watchdog = {
      pollInterval = 5;
      startupGrace = 8;

      dns = {
        enable = true;
        zoneId = "b6558c4a7b3b0a1c62d5f8e9d0f12345"; # same zone as node1
        nodeAddress = "203.0.113.12"; # public IPv4 of this node (node2)
        ttl = 60;
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Example: sops-nix secrets
  # ---------------------------------------------------------------------------
  # sops.secrets.litestream = {
  #   sopsFile = ./secrets/node2.yaml;
  #   owner    = "root";
  #   mode     = "0400";
  #   path     = "/run/secrets/litestream";
  # };
  #
  # sops.secrets."caddy-cloudflare-token" = {
  #   sopsFile = ./secrets/node2.yaml;
  #   owner    = "caddy";
  #   mode     = "0400";
  #   path     = "/run/secrets/caddy-cloudflare-token";
  # };
  #
  # -- mTLS certs (generate with scripts/gen-cluster-certs.sh) ----------
  # sops.secrets."le-ca.crt" = {
  #   sopsFile = ./secrets/cluster-ca.yaml;
  #   mode     = "0444";
  #   path     = "/run/secrets/le-ca.crt";
  # };
  # sops.secrets."le-node2.crt" = {
  #   sopsFile = ./secrets/node2.yaml;
  #   mode     = "0444";
  #   path     = "/run/secrets/le-node2.crt";
  # };
  # sops.secrets."le-node2.key" = {
  #   sopsFile = ./secrets/node2.yaml;
  #   mode     = "0400";
  #   path     = "/run/secrets/le-node2.key";
  # };

  # ---------------------------------------------------------------------------
  # Firewall
  # ---------------------------------------------------------------------------
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22
      80
      443
    ];
    allowedUDPPorts = [41641];
  };

  # ---------------------------------------------------------------------------
  # SSH
  # ---------------------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  system.stateVersion = "24.11";
}
