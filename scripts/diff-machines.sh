#!/usr/bin/env bash
set -euo pipefail

# Quick diff between two DGX Spark machines (no Ansible required)

HOST_A="${1:-source-node}"
HOST_B="${2:-target-node}"
MANAGED_USER="${MANAGED_USER:-admin}"

echo "=== Package diff ($HOST_A vs $HOST_B) ==="
diff --color=auto \
    <(ssh "$HOST_A" "apt-mark showmanual | sort") \
    <(ssh "$HOST_B" "apt-mark showmanual | sort") \
    || true

echo ""
echo "=== Group diff ($MANAGED_USER) ==="
# shellcheck disable=SC2029
echo "$HOST_A: $(ssh "$HOST_A" "id -nG '$MANAGED_USER'")"
# shellcheck disable=SC2029
echo "$HOST_B: $(ssh "$HOST_B" "id -nG '$MANAGED_USER'")"

echo ""
echo "=== Enabled services diff ==="
diff --color=auto \
    <(ssh "$HOST_A" "systemctl list-unit-files --type=service --state=enabled --no-pager | grep '\.service' | awk '{print \$1}' | sort") \
    <(ssh "$HOST_B" "systemctl list-unit-files --type=service --state=enabled --no-pager | grep '\.service' | awk '{print \$1}' | sort") \
    || true

echo ""
echo "=== Masked services diff ==="
diff --color=auto \
    <(ssh "$HOST_A" "systemctl list-unit-files --type=service --state=masked --no-pager | grep '\.service' | awk '{print \$1}' | sort") \
    <(ssh "$HOST_B" "systemctl list-unit-files --type=service --state=masked --no-pager | grep '\.service' | awk '{print \$1}' | sort") \
    || true

echo ""
echo "=== DGX Release ==="
echo "$HOST_A: $(ssh "$HOST_A" 'grep DGX_OTA_VERSION /etc/dgx-release 2>/dev/null || echo "N/A"')"
echo "$HOST_B: $(ssh "$HOST_B" 'grep DGX_OTA_VERSION /etc/dgx-release 2>/dev/null || echo "N/A"')"
