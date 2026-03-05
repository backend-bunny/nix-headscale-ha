#!/usr/bin/env bash
# tests/run-e2e.sh
#
# End-to-end test runner for headscale-ha.
#
# The test itself is fully hermetic: it spins up four QEMU VMs, runs Garage
# inside the test for S3 storage, and generates ephemeral mTLS certificates
# as a Nix derivation.  No external accounts are required for the core test.
#
# Optional: export real Cloudflare / Backblaze credentials before running to
# test the watchdog DNS update and real S3 replication paths.  When these env
# vars are set the test switches litestream to real B2 and enables the CF DNS
# watchdog.  The credentials can alternatively be sourced from the
# SOPS-encrypted tests/secrets.yaml (see --decrypt flag).
#
# USAGE
#   ./tests/run-e2e.sh [OPTIONS]
#
# OPTIONS
#   --decrypt           Decrypt tests/secrets.yaml with sops and export the
#                       credentials as environment variables before running the
#                       test.  Requires SOPS_AGE_KEY_FILE or SOPS_AGE_KEY to
#                       be set, or a GPG key in the sops YAML recipients list.
#
#   --no-sandbox        Pass --option sandbox false to nix build.  Required on
#                       some distributions where /proc/self/ns/user is not
#                       available for nested virtualisation.  Also needed when
#                       the test VMs need outbound network access (e.g. for
#                       real B2/CF credential testing).
#
#   --keep-vm           Do not delete the VM state directory after the test
#                       (useful for debugging).
#
#   --show-trace        Pass --show-trace to nix build for detailed Nix eval
#                       errors.
#
#   -j N, --jobs N      Number of parallel Nix build jobs (default: auto).
#
#   --help              Show this message.
#
# ENVIRONMENT VARIABLES (optional — real-credential mode)
#   E2E_B2_KEY_ID           Backblaze B2 / S3 application key ID
#   E2E_B2_APP_KEY          Backblaze B2 / S3 application key secret
#   E2E_B2_BUCKET           Bucket name (must already exist)
#   E2E_B2_ENDPOINT         S3-compatible endpoint URL (e.g. https://s3.us-west-002.backblazeb2.com)
#   E2E_CF_API_TOKEN        Cloudflare API token (DNS:Edit on target zone)
#   E2E_CF_ZONE_ID          Cloudflare Zone ID
#   E2E_CF_RECORD_NAME      DNS A record to update on promotion (e.g. headscale.example.com)
#
# PREREQUISITES
#   • Nix with flakes enabled  (nixpkgs.experimental-features = "nix-command flakes")
#   • KVM / nested virtualisation available  (ls /dev/kvm)
#   • sops (only needed with --decrypt)
#   • At least 4 GiB free RAM (four QEMU VMs: 3×768 MiB + 1×384 MiB)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
DECRYPT=false
NO_SANDBOX=false
KEEP_VM=false
SHOW_TRACE=false
NIX_JOBS="auto"

# ── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --decrypt)     DECRYPT=true  ;;
    --no-sandbox)  NO_SANDBOX=true ;;
    --keep-vm)     KEEP_VM=true ;;
    --show-trace)  SHOW_TRACE=true ;;
    -j|--jobs)     NIX_JOBS="$2"; shift ;;
    --help|-h)
      sed -n '3,60p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "Unknown option: $1  (run with --help for usage)" >&2
      exit 1 ;;
  esac
  shift
done

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[run-e2e]${NC} $*"; }
warn()  { echo -e "${YELLOW}[run-e2e]${NC} $*"; }
error() { echo -e "${RED}[run-e2e]${NC} $*" >&2; }

# ── Prerequisite checks ──────────────────────────────────────────────────────
info "Checking prerequisites..."

if ! command -v nix >/dev/null 2>&1; then
  error "nix is not installed.  See https://nixos.org/download"
  exit 1
fi

if ! nix --version | grep -q 'nix (Nix) 2\.[89]\|nix (Nix) [3-9]'; then
  warn "Nix ≥ 2.8 recommended for flake support."
fi

if [[ ! -e /dev/kvm ]]; then
  error "/dev/kvm not available.  Enable KVM or run with --no-sandbox and hardware virtualisation."
  exit 1
fi

if $DECRYPT && ! command -v sops >/dev/null 2>&1; then
  error "sops is required for --decrypt.  Install with: nix shell nixpkgs#sops"
  exit 1
fi

# ── Optional: decrypt SOPS secrets and export credentials ────────────────────
if $DECRYPT; then
  SECRETS_FILE="$SCRIPT_DIR/secrets.yaml"
  if [[ ! -f "$SECRETS_FILE" ]]; then
    error "tests/secrets.yaml not found.  Create it with tests/gen-test-secrets.sh"
    error "(see tests/secrets.yaml.example for the required structure)"
    exit 1
  fi

  info "Decrypting tests/secrets.yaml with sops..."
  DECRYPTED="$(sops --decrypt "$SECRETS_FILE")"

  _sops_get() { printf '%s' "$DECRYPTED" | python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin)
keys = '${1}'.split('/')
val = data
for k in keys:
    val = val[k]
print(val, end='')"; }

  # Only export if the key exists and is non-empty
  _try_export() {
    local var="$1" key="$2"
    local val; val="$(_sops_get "$key" 2>/dev/null || true)"
    [[ -n "$val" ]] && export "$var=$val" && info "Exported $var from secrets.yaml"
  }

  _try_export E2E_B2_KEY_ID    "litestream/b2_key_id"
  _try_export E2E_B2_APP_KEY   "litestream/b2_application_key"
  _try_export E2E_B2_BUCKET    "litestream/b2_bucket"
  _try_export E2E_B2_ENDPOINT  "litestream/b2_endpoint"
  _try_export E2E_CF_API_TOKEN "cloudflare/api_token"
  _try_export E2E_CF_ZONE_ID   "cloudflare/zone_id"
  _try_export E2E_CF_RECORD_NAME "cloudflare/record_name"
fi

# ── Detect real-credential mode ───────────────────────────────────────────────
USE_REAL_CREDS=false
if [[ -n "${E2E_B2_KEY_ID:-}" && -n "${E2E_B2_APP_KEY:-}" ]]; then
  USE_REAL_CREDS=true
  info "Real B2 credentials detected — test will use Backblaze B2 for litestream."
  NO_SANDBOX=true  # real credentials mode needs outbound network from VMs
fi

if [[ "${USE_REAL_CREDS}" == "true" ]]; then
  warn "NOTE: Real credentials mode requires --no-sandbox (network access from VMs)"
  warn "      The test VMs will write to bucket: ${E2E_B2_BUCKET:-headscale-e2e-test}"
fi

# ── Build Nix command ─────────────────────────────────────────────────────────
NIX_ARGS=(
  "build"
  "--no-link"
  "-L"                          # show build logs
  "-j" "$NIX_JOBS"
)

$SHOW_TRACE  && NIX_ARGS+=( "--show-trace" )
$NO_SANDBOX  && NIX_ARGS+=( "--option" "sandbox" "false" )

# Pass real credentials into the Nix build via builtins.getEnv (requires --impure)
if $USE_REAL_CREDS; then
  NIX_ARGS+=( "--impure" )
  NIX_ARGS+=( ".#checks.x86_64-linux.e2e-real-creds" )
else
  NIX_ARGS+=( ".#checks.x86_64-linux.e2e" )
fi

# ── Run the test ─────────────────────────────────────────────────────────────
info "Running e2e test..."
info "  nix ${NIX_ARGS[*]}"
echo ""

cd "$REPO_ROOT"

START_TIME="$(date +%s)"
if nix "${NIX_ARGS[@]}"; then
  END_TIME="$(date +%s)"
  ELAPSED="$(( END_TIME - START_TIME ))"
  echo ""
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  info "  ALL TESTS PASSED  (${ELAPSED}s)"
  info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  echo ""
  error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  error "  TEST FAILED"
  error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  error "Re-run with --show-trace for more detail."
  error "Re-run with --keep-vm to inspect VM state after failure."
  exit 1
fi
