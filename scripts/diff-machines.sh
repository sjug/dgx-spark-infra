#!/usr/bin/env bash
set -euo pipefail

# Quick diff between two DGX Spark machines (no Ansible required)

HOST_A="${1:-source-node}"
HOST_B="${2:-target-node}"
MANAGED_USER="${MANAGED_USER:-admin}"
DGX_SSH_CONFIG="${DGX_SSH_CONFIG:-}"

run_ssh() {
    if [ -n "$DGX_SSH_CONFIG" ]; then
        ssh -F "$DGX_SSH_CONFIG" "$@"
    else
        ssh "$@"
    fi
}

dgx_ota_version() {
    local host="$1"

    # shellcheck disable=SC2016
    run_ssh "$host" '
        versions=$(grep "^DGX_OTA_VERSION=" /etc/dgx-release 2>/dev/null || true)
        if [ -z "$versions" ]; then
            echo "N/A"
            exit 0
        fi

        effective=$(printf "%s\n" "$versions" | tail -n 1)
        count=$(printf "%s\n" "$versions" | wc -l)
        if [ "$count" -gt 1 ]; then
            printf "%s (duplicate entries: %s)\n" "$effective" "$count"
        else
            printf "%s\n" "$effective"
        fi
    '
}

echo "=== Manually marked package diff ($HOST_A vs $HOST_B) ==="
diff --color=auto \
    <(run_ssh "$HOST_A" "apt-mark showmanual | sort") \
    <(run_ssh "$HOST_B" "apt-mark showmanual | sort") \
    || true

echo ""
echo "=== Group diff ($MANAGED_USER) ==="
# shellcheck disable=SC2029
echo "$HOST_A: $(run_ssh "$HOST_A" "id -nG '$MANAGED_USER'")"
# shellcheck disable=SC2029
echo "$HOST_B: $(run_ssh "$HOST_B" "id -nG '$MANAGED_USER'")"

echo ""
echo "=== Enabled services diff ==="
diff --color=auto \
    <(run_ssh "$HOST_A" "systemctl list-unit-files --type=service --state=enabled --no-pager | grep '\.service' | awk '{print \$1}' | sort") \
    <(run_ssh "$HOST_B" "systemctl list-unit-files --type=service --state=enabled --no-pager | grep '\.service' | awk '{print \$1}' | sort") \
    || true

echo ""
echo "=== Masked services diff ==="
diff --color=auto \
    <(run_ssh "$HOST_A" "systemctl list-unit-files --type=service --state=masked --no-pager | grep '\.service' | awk '{print \$1}' | sort") \
    <(run_ssh "$HOST_B" "systemctl list-unit-files --type=service --state=masked --no-pager | grep '\.service' | awk '{print \$1}' | sort") \
    || true

echo ""
echo "=== DGX Release ==="
echo "$HOST_A: $(dgx_ota_version "$HOST_A")"
echo "$HOST_B: $(dgx_ota_version "$HOST_B")"
