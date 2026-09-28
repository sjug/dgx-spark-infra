#!/usr/bin/env bash
# Inspect installed packages that a PPA publishes.
#
#   list       installed packages the PPA publishes (held ones included)
#   held       installed packages the PPA publishes that are on hold
#   candidate  "<pkg> <version> <origin>" for each whose apt candidate is
#              not offered by the PPA alone
#   installed  "<pkg> <version> <origin>" for each whose installed version
#              is not offered by the PPA alone. Launchpad lists only the
#              newest build, so an older PPA build reports origin "none".
#
# origin is one of: other (another repo only), both (the PPA and another
# repo, so apt may download from either), none (no repo offers it).
#
# APT_POLICY_SOURCE is the PPA host/path as shown by apt-cache policy,
# e.g. ppa.launchpadcontent.net/sejug/podman. Exits 1 when no package
# index for the PPA exists, so a missing index never looks like "nothing
# to upgrade".
set -euo pipefail

usage() {
  echo "usage: $0 list|held|candidate|installed APT_POLICY_SOURCE" >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
mode=$1
source=${2%/}
case "$mode" in list | held | candidate | installed) ;; *) usage ;; esac

prefix=${source//\//_}
shopt -s nullglob
indexes=(/var/lib/apt/lists/"${prefix}"_ubuntu_dists_*_Packages{,.lz4,.gz,.xz,.zst})

if [[ ${#indexes[@]} -eq 0 ]]; then
  echo "no apt package index found for $source; run apt-get update" >&2
  exit 1
fi

# Print installed PPA-published packages. With "held", only those on hold.
# db:Status-Abbrev is <selection><state><error>: "ii" installed, "hi" held.
installed_ppa_packages() {
  local want_held=$1 index pkg status
  for index in "${indexes[@]}"; do
    /usr/lib/apt/apt-helper cat-file "$index"
  done | awk '/^Package:/ { print $2 }' | sort -u | while read -r pkg; do
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || true)"
    [[ "${status:1:1}" == i ]] || continue
    if [[ "$want_held" == no || "${status:0:1}" == h ]]; then
      echo "$pkg"
    fi
  done
}

# Print where VERSION of PKG is offered: ppa, both, other or none.
# apt-cache policy indents version lines by 5 (" *** " when installed)
# and their source lines deeper (priorities are right-aligned), which also
# parses purely numeric versions.
version_origin() {
  apt-cache policy "$1" | awk -v want="$2" -v src="$source/" '
    /^ \*\*\* / { v = $2; next }
    /^     [^ ]/ { v = $1; next }
    match($0, /^ +/) && RLENGTH > 5 && v == want && $2 != "/var/lib/dpkg/status" {
      if (index($2, src)) p = 1; else o = 1
    }
    END { print (p && o) ? "both" : p ? "ppa" : o ? "other" : "none" }
  '
}

case "$mode" in
  list)
    installed_ppa_packages no
    exit 0
    ;;
  held)
    installed_ppa_packages yes
    exit 0
    ;;
  candidate) field=Candidate ;;
  installed) field=Installed ;;
esac

for pkg in $(installed_ppa_packages no); do
  version="$(apt-cache policy "$pkg" | awk -v f="$field:" '$1 == f && !seen { print $2; seen = 1 }')"
  origin="$(version_origin "$pkg" "$version")"
  if [[ "$origin" != ppa ]]; then
    echo "$pkg $version $origin"
  fi
done
