#!/usr/bin/env bash
# Regenerates Shirox/Resources/adult_hosts.txt from a porn-only host list.
# Porn-only (NOT the unified StevenBlack list) so we don't block ad/malware/CDN hosts
# that legitimate streaming modules may rely on.
set -euo pipefail
SRC="https://raw.githubusercontent.com/Sinfonietta/hostfiles/master/pornography-hosts"
OUT="$(dirname "$0")/../Shirox/Resources/adult_hosts.txt"
mkdir -p "$(dirname "$OUT")"
{
  echo "# Adult host blocklist for Shirox — porn-only."
  echo "# Source: $SRC"
  echo "# Regenerate with scripts/fetch_adult_hosts.sh"
  curl -fsSL "$SRC"
} > "$OUT"
echo "Wrote $(grep -vc '^#' "$OUT") host lines to $OUT"
