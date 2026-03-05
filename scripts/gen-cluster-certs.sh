#!/usr/bin/env bash
# scripts/gen-cluster-certs.sh
#
# Bootstrap the leader-election cluster PKI.
#
# Generates a self-signed cluster CA and one certificate per node.  Each node
# certificate contains the node's IP address as an IP Subject Alternative Name
# so that Go's TLS stack can verify the server when dialling https://IP:port.
#
# USAGE
#   scripts/gen-cluster-certs.sh <name:IP> [<name:IP> ...]
#
# EXAMPLE
#   scripts/gen-cluster-certs.sh node1:192.168.1.11 node2:192.168.1.12 node3:192.168.1.13
#
# OUTPUT  (in ./pki/)
#   ca.crt           cluster CA certificate  — distribute to every node
#   ca.key           cluster CA private key  — keep ONLY on the machine that ran this script
#   <name>.crt       node certificate        — copy to the corresponding node
#   <name>.key       node private key        — copy to the corresponding node only
#
# SOPS-NIX WORKFLOW
#   1. Run this script once on a trusted machine (e.g. your workstation).
#   2. Encrypt each file with sops/age and commit to your secrets repo.
#   3. Reference the decrypted paths in node*.nix configurations (see nixos/).
#   4. Re-run every ~2 years when node certificates expire (CA is valid 10 years).
#
# REQUIREMENTS
#   openssl (any modern version, 1.1.1+ or 3.x)
#
# NOTE ON RENEWAL
#   To renew a single node cert without regenerating the CA or other nodes,
#   run:  NAME=node1 IP=192.168.1.11 ./scripts/gen-cluster-certs.sh node1:192.168.1.11
#   This overwrites only node1.key / node1.crt in ./pki/.
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OUT_DIR="${PKI_DIR:-./pki}"
CA_SUBJECT="${CA_SUBJECT:-/O=headscale-ha/CN=headscale-le-cluster-ca}"
CA_DAYS="${CA_DAYS:-3650}"     # 10 years
NODE_DAYS="${NODE_DAYS:-730}"  # 2 years
KEY_BITS="${KEY_BITS:-4096}"

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 <name:IP> [<name:IP> ...]" >&2
  echo "  e.g. $0 node1:192.168.1.11 node2:192.168.1.12 node3:192.168.1.13" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Generate cluster CA (skip if ca.key already exists)
# ---------------------------------------------------------------------------
if [[ -f "$OUT_DIR/ca.key" && -f "$OUT_DIR/ca.crt" ]]; then
  echo "==> Reusing existing cluster CA ($OUT_DIR/ca.crt)"
else
  echo "==> Generating cluster CA ($KEY_BITS-bit RSA, valid ${CA_DAYS} days)"
  openssl genrsa -out "$OUT_DIR/ca.key" "$KEY_BITS" 2>/dev/null
  openssl req -new -x509 \
    -key     "$OUT_DIR/ca.key" \
    -out     "$OUT_DIR/ca.crt" \
    -days    "$CA_DAYS" \
    -subj    "$CA_SUBJECT" \
    -addext  "basicConstraints=critical,CA:TRUE" \
    -addext  "keyUsage=critical,keyCertSign,cRLSign"
  chmod 600 "$OUT_DIR/ca.key"
  chmod 644 "$OUT_DIR/ca.crt"
  echo "    CA key:  $OUT_DIR/ca.key  (keep secret — never distribute)"
  echo "    CA cert: $OUT_DIR/ca.crt  (distribute to every node)"
fi

# ---------------------------------------------------------------------------
# 2. Generate one key + certificate per node
# ---------------------------------------------------------------------------
for SPEC in "$@"; do
  NAME="${SPEC%%:*}"
  IP="${SPEC##*:}"

  if [[ -z "$NAME" || -z "$IP" ]]; then
    echo "ERROR: invalid spec '$SPEC' — expected 'name:IP'" >&2
    exit 1
  fi

  echo ""
  echo "==> Node: $NAME  IP: $IP"

  # Per-node OpenSSL config with the IP SAN.
  EXT_CNF="$TMPDIR/${NAME}.ext.cnf"
  cat > "$EXT_CNF" <<EOF
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = ${NAME}
O  = headscale-ha
[v3_node]
basicConstraints       = CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = serverAuth, clientAuth
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always
subjectAltName         = IP:${IP}, DNS:${NAME}
EOF

  # Generate node private key
  openssl genrsa -out "$OUT_DIR/${NAME}.key" "$KEY_BITS" 2>/dev/null
  chmod 600 "$OUT_DIR/${NAME}.key"

  # Generate CSR
  openssl req -new \
    -key    "$OUT_DIR/${NAME}.key" \
    -out    "$TMPDIR/${NAME}.csr" \
    -subj   "/O=headscale-ha/CN=${NAME}"

  # Sign with cluster CA
  openssl x509 -req \
    -in          "$TMPDIR/${NAME}.csr" \
    -CA          "$OUT_DIR/ca.crt" \
    -CAkey       "$OUT_DIR/ca.key" \
    -CAcreateserial \
    -out         "$OUT_DIR/${NAME}.crt" \
    -days        "$NODE_DAYS" \
    -extfile     "$EXT_CNF" \
    -extensions  v3_node \
    2>/dev/null
  chmod 644 "$OUT_DIR/${NAME}.crt"

  echo "    key:  $OUT_DIR/${NAME}.key"
  echo "    cert: $OUT_DIR/${NAME}.crt"

  # Show SANs for verification
  echo -n "    SANs: "
  openssl x509 -in "$OUT_DIR/${NAME}.crt" -noout -ext subjectAltName 2>/dev/null \
    | grep -v "^X509v3" | tr -d ' ' | head -1
done

# ---------------------------------------------------------------------------
# 3. Verify all node certs against the CA
# ---------------------------------------------------------------------------
echo ""
echo "==> Verifying all node certificates against the cluster CA..."
ALL_OK=true
for SPEC in "$@"; do
  NAME="${SPEC%%:*}"
  if openssl verify -CAfile "$OUT_DIR/ca.crt" "$OUT_DIR/${NAME}.crt" > /dev/null 2>&1; then
    echo "    OK  $OUT_DIR/${NAME}.crt"
  else
    echo "    FAIL $OUT_DIR/${NAME}.crt" >&2
    ALL_OK=false
  fi
done

if $ALL_OK; then
  echo ""
  echo "==> All certificates OK."
  echo ""
  echo "Next steps:"
  echo "  1. Encrypt the generated files with sops/age."
  echo "  2. Commit to your secrets repository."
  echo "  3. Reference the paths in your node NixOS configs (see nixos/node*.nix)."
  echo ""
  echo "Distribution guide:"
  echo "  Every node needs:  ca.crt  (CA certificate, not secret)"
  echo "  nodeN only needs:  nodeN.key  nodeN.crt  (node-specific, keep separate)"
else
  echo ""
  echo "ERROR: some certificates failed to verify — check the output above." >&2
  exit 1
fi
