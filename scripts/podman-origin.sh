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

# Prints absent, ppa, non-ppa or unknown. Only non-ppa (the installed
# version is offered by another repository and not by the PPA) is safe to
# act on. The PPA lists only its newest build, so an older PPA build is
# offered by nobody and reports unknown, as does a version both offer.
# apt-cache policy indents version lines by 5 (" *** " when installed)
# and their source lines deeper (priorities are right-aligned).
apt-cache policy podman | awk -v want="$installed" -v src="${policy_source%/}/" '
  /^ \*\*\* / { v = $2; next }
  /^     [^ ]/ { v = $1; next }
  match($0, /^ +/) && RLENGTH > 5 && v == want && $2 != "/var/lib/dpkg/status" {
    if (index($2, src)) p = 1; else o = 1
  }
  END { print (p && !o) ? "ppa" : (o && !p) ? "non-ppa" : "unknown" }
'
