#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 APT_POLICY_SOURCE" >&2
  exit 2
fi

policy_source=$1
installed="$(dpkg-query -W -f='${Version}' podman 2>/dev/null || true)"

if [[ -z "$installed" ]]; then
  echo absent
  exit 0
fi

apt-cache policy podman | awk -v installed="$installed" -v source="$policy_source" '
  $1 == "***" && $2 == installed { active = 1; next }
  active && $1 != "" && $2 ~ /^[0-9]+$/ { active = 0 }
  active && index($0, source) { found = 1 }
  END { print found ? "ppa" : "non-ppa" }
'
