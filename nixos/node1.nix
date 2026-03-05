# nixos/node1.nix
#
# Example NixOS configuration for the first cluster node.
#
# This node has priority 10 (lower = preferred primary), so it will be the
# primary whenever it is healthy.  node2 (priority 20) takes over if node1
# goes down.
#
# Adjust IP addresses, hostnames, disk layout, and secrets paths to match
# your environment.  This file is intentionally minimal — combine it with
# your usual NixOS base config (bootloader, users, SSH, monitoring, etc.).
{ config, pkgs, lib, ... }:

{
  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------
  networking.hostName = "headscale-node1";

  # Static IP used by node2 to reach the leader-election daemon and headscale.
  # Adjust to your network layout.
  networking.interfaces.eth0.ipv4.addresses = [{
    address      = "192.168.1.11";
    prefixLength = 24;
  }];
  networking.defaultGateway  = "192.168.1.1";
  networking.nameservers     = [ "1.1.1.1" "8.8.8.8" ];

  # ---------------------------------------------------------------------------
  # Headscale HA stack
  # ---------------------------------------------------------------------------
  services.headscaleHa = {
    enable = true;

    # -- Node identity --------------------------------------------------------
    node = {
      id       = "node1";
      priority = 10;            # ← preferred primary (lower wins)
      peers    = [
        "https://192.168.1.12:50556"  # node2 mTLS peer-gossip endpoint
        "https://192.168.1.13:50556"  # node3 mTLS peer-gossip endpoint
      ];
      leaderElectionPort         = 50555;
      openLeaderElectionFirewall = true;   # allow peers in (opens 50555 + 50556)

      # mTLS peer authentication — all three files required.
      # Generate the cluster PKI once with scripts/gen-cluster-certs.sh.
      tls = {
        caFile   = "/run/secrets/le-ca.crt";
        certFile = "/run/secrets/le-node1.crt";
        keyFile  = "/run/secrets/le-node1.key";
        # listenAddr = ":50556";  # default
      };
    };

    # -- Litestream -----------------------------------------------------------
    # Credentials are in a secrets file managed by, e.g., agenix or sops-nix.
    # The file must contain:
    #   LITESTREAM_ACCESS_KEY_ID=...
    #   LITESTREAM_SECRET_ACCESS_KEY=...
    litestream = {
      credentialsFile = "/run/secrets/litestream";  # provisioned by sops-nix / agenix

      replica = {
        type     = "s3";
        bucket   = "my-headscale-ha";
        path     = "db";
        # For Garage: set endpoint = "http://garage.internal:9000"
        # For AWS S3: leave endpoint empty and set the correct region.
        endpoint = "";          # empty = AWS S3
        region   = "eu-west-1";
        retention    = "24h";
        syncInterval = "1s";
      };
    };

    # -- Headscale settings ---------------------------------------------------
    headscale.settings = {
      server_url           = "https://headscale.example.com";
      listen_addr          = "0.0.0.0:8080";
      grpc_listen_addr     = "0.0.0.0:50443";
      metrics_listen_addr  = "127.0.0.1:9090";
      log.level            = "info";

      prefixes = {
        v4         = "100.64.0.0/10";
        v6         = "fd7a:115c:a1e0::/48";
        allocation = "sequential";
      };

      dns = {
        magic_dns   = true;
        base_domain = "ts.example.com";
        nameservers.global = [ "1.1.1.1" ];
      };

      # Use the OIDC provider of your choice, or comment out for pre-auth keys.
      # oidc = {
      #   issuer        = "https://auth.example.com";
      #   client_id     = "headscale";
      #   client_secret_path = "/run/secrets/headscale-oidc-secret";
      # };
    };

    # -- Caddy ----------------------------------------------------------------
    # Caddy runs on every node.  Both nodes proxy to both upstreams; the active
    # health check routes traffic only to the current primary.
    caddy = {
      enable     = true;
      serverName = "headscale.example.com";
      acmeEmail  = "admin@example.com";

      # Cloudflare DNS-01 TLS — no inbound HTTP-01 traffic needed.
      # The token file must be a systemd EnvironmentFile containing:
      #   CLOUDFLARE_DNS_API_TOKEN=cfxxxxxxxxxxxxxxxx
      cloudflare = {
        enable    = true;
        tokenFile = "/run/secrets/caddy-cloudflare-token";
        # Optionally pin a pre-built package from this flake:
        # caddyPackage = inputs.nix-headscale-ha.packages.x86_64-linux.caddy-cloudflare;
      };

      # For a private/LAN deployment without a public domain, use instead:
      #   cloudflare.enable = false;
      #   acmeEmail         = "";
      #   tls.extraConfig   = "tls internal";

      nodes = [
        { address = "192.168.1.11"; httpPort = 8080; grpcPort = 50443; }  # node1
        { address = "192.168.1.12"; httpPort = 8080; grpcPort = 50443; }  # node2
        { address = "192.168.1.13"; httpPort = 8080; grpcPort = 50443; }  # node3
      ];
    };

    # -- Watchdog -------------------------------------------------------------
    watchdog = {
      pollInterval = 5;
      startupGrace = 8;  # give the cluster 8 s to elect after boot

      # DNS failover: on promotion, point headscale.example.com at this node.
      # tokenFile and recordName default to the Caddy cloudflare values above,
      # so only zoneId and nodeAddress need to be specified here.
      dns = {
        enable      = true;
        zoneId      = "b6558c4a7b3b0a1c62d5f8e9d0f12345";  # your CF Zone ID
        nodeAddress = "203.0.113.11";  # public IPv4 of this node (node1)
        ttl         = 60;              # 60 s = CF minimum; enables fast failover
        # tokenFile  = ...;  # defaults to caddy.cloudflare.tokenFile
        # recordName = ...;  # defaults to caddy.serverName
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Example: sops-nix secrets
  # (Uncomment and adapt if you are using sops-nix.)
  # ---------------------------------------------------------------------------
  # sops.secrets.litestream = {
  #   sopsFile = ./secrets/node1.yaml;
  #   owner    = "root";
  #   mode     = "0400";
  #   path     = "/run/secrets/litestream";
  # };
  #
  # # Cloudflare API token for Caddy DNS-01 ACME challenge.
  # # The secret value in the sops YAML file must be the raw EnvironmentFile line:
  # #   CLOUDFLARE_DNS_API_TOKEN=cfxxxxxxxxxxxxxxxx
  # sops.secrets."caddy-cloudflare-token" = {
  #   sopsFile = ./secrets/node1.yaml;
  #   owner    = "caddy";   # must match the Caddy systemd service user
  #   mode     = "0400";
  #   path     = "/run/secrets/caddy-cloudflare-token";
  # };
  #
  # # mTLS certs for leader-election peer gossip.
  # # Generate the full cluster PKI once with: scripts/gen-cluster-certs.sh
  # sops.secrets."le-ca.crt" = {
  #   sopsFile = ./secrets/cluster-ca.yaml;  # shared across all nodes
  #   mode     = "0444";                     # CA cert is not sensitive
  #   path     = "/run/secrets/le-ca.crt";
  # };
  # sops.secrets."le-node1.crt" = {
  #   sopsFile = ./secrets/node1.yaml;
  #   mode     = "0444";
  #   path     = "/run/secrets/le-node1.crt";
  # };
  # sops.secrets."le-node1.key" = {
  #   sopsFile = ./secrets/node1.yaml;
  #   mode     = "0400";
  #   path     = "/run/secrets/le-node1.key";
  # };

  # ---------------------------------------------------------------------------
  # Firewall
  # ---------------------------------------------------------------------------
  networking.firewall = {
    enable          = true;
    allowedTCPPorts = [
      22    # SSH
      80    # Caddy HTTP  (redirects to HTTPS)
      443   # Caddy HTTPS + gRPC
      # 50555 is opened by openLeaderElectionFirewall = true above
    ];
    # Tailscale UDP
    allowedUDPPorts = [ 41641 ];
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
