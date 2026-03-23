#!/usr/bin/env bash
set -euo pipefail

# Capture script for dgx-spark-infra
# Connects to the source-of-truth machine and captures its state
# into Ansible variable files and config file copies.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CAPTURE_DIR="$PROJECT_DIR/captured_state"
GROUP_VARS="$PROJECT_DIR/inventory/group_vars/dgx_spark.yml"

SOURCE_HOST="${1:-source-node}"
MANAGED_USER="${MANAGED_USER:-admin}"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

echo "=== DGX Spark State Capture ==="
echo "Source: $SOURCE_HOST"
echo "Managed user: $MANAGED_USER"
echo "Timestamp: $TIMESTAMP"
echo ""

# Create capture directories
mkdir -p "$CAPTURE_DIR/config_files"/{etc_sysctl.d,etc_modprobe.d,etc_nvidia-container-runtime,etc_containerd,etc_ssh_sshd_config.d,etc_NetworkManager_conf.d,etc_default}

# Start each capture from a clean slate so removed source files disappear
# from the captured state instead of lingering indefinitely.
find "$CAPTURE_DIR/config_files" -type f -delete

# ============================================================
# 1. Capture APT packages (manually installed)
# ============================================================
echo "--- Capturing APT packages ---"

ssh "$SOURCE_HOST" "apt-mark showmanual" | sort > "$CAPTURE_DIR/packages_raw.txt"

# Filter out base system, NVIDIA OTA-managed, and desktop packages
FILTER_PATTERNS=(
    # Base system
    '^adduser$' '^apt$' '^base-files$' '^base-passwd$' '^bash$' '^bsdutils$'
    '^coreutils$' '^dash$' '^debconf$' '^debianutils$' '^diffutils$'
    '^dpkg$' '^e2fsprogs$' '^findutils$' '^grep$' '^gzip$' '^hostname$'
    '^init$' '^login$' '^mount$' '^ncurses-' '^passwd$' '^procps$'
    '^sed$' '^sensible-utils$' '^sudo$' '^sysvinit-utils$' '^tar$'
    '^util-linux$' '^zlib1g$'
    # Ubuntu meta/base
    '^ubuntu-' '^snapd$'
    # Kernel/boot
    '^linux-' '^shim-signed$' '^grub-efi-' '^efibootmgr$' '^efivar$'
    '^secureboot-db$' '^mokutil$' '^sbsigntool$'
    # NVIDIA system packages managed by DGX OTA
    '^nvidia-conf-' '^nvidia-console-' '^nvidia-cppc-' '^nvidia-disable-'
    '^nvidia-drm-' '^nvidia-earlycon' '^nvidia-enable-' '^nvidia-grub'
    '^nvidia-hibernate' '^nvidia-modprobe$' '^nvidia-mstflint'
    '^nvidia-no-systemd' '^nvidia-oem-' '^nvidia-pci-' '^nvidia-raid-'
    '^nvidia-redfish-' '^nvidia-resume' '^nvidia-sbsa-' '^nvidia-settings$'
    '^nvidia-spark-desktop' '^nvidia-spark-mlnx' '^nvidia-spark-remove'
    '^nvidia-spark-wifi' '^nvidia-suspend' '^nvidia-system-'
    '^nvidia-driver-' '^nvidia-remove-' '^nvidia-cdi-'
    '^nv-docker-gpus$' '^nv-no-grubmenu$' '^nv-vulkan-' '^nv-xorg-'
    '^nvidia-ai-workbench$'
    # DGX OTA packages
    '^dgx-' '^ai-workbench-' '^cuda-compute-repo' '^cuda-nvml-dev'
    '^cuda-toolkit' '^mlnx-pxe-setup$' '^nvidia-dgx-' '^nvidia-spark-run'
    # GNOME/desktop
    '^gnome-' '^gdm' '^nautilus' '^firefox' '^totem' '^evince' '^eog$'
    '^xwayland' '^yelp$' '^snap:' '^thunderbird'
    # Libs that are auto-pulled (but sometimes marked manual by installers)
    '^libnvidia-' '^libcuda' '^libnccl'
)

FILTER_REGEX=$(printf '%s\n' "${FILTER_PATTERNS[@]}" | paste -sd'|')
grep -Ev "$FILTER_REGEX" "$CAPTURE_DIR/packages_raw.txt" > "$CAPTURE_DIR/packages_filtered.txt" || true

echo "  Captured $(wc -l < "$CAPTURE_DIR/packages_filtered.txt") packages (from $(wc -l < "$CAPTURE_DIR/packages_raw.txt") total manual)"

# ============================================================
# 2. Capture systemd services
# ============================================================
echo "--- Capturing systemd services ---"

# Service patterns to EXCLUDE (system internals, DGX OTA-managed, transient)
SERVICE_EXCLUDE='(systemd-|getty@|console-|keyboard-|setvtrgb|finalrd|e2scrub|blk-availability|lvm2|grub-|secureboot|snapd|snap[.]|apparmor|dmesg|ssl-cert|ras-mc|rasdaemon|rsyslog|networkd-|NetworkManager|avahi|anacron|cron|cfg-iommu|nv-cpu-governor|nv-docker-gpus|nvidia-conf|nvidia-console|nvidia-disable|nvidia-earlycon|nvidia-enable|nvidia-grub|nvidia-nvme|nvidia-pci|nvidia-raid|nvidia-redfish|nvidia-persist|nvidia-spark-run|nvmefc|nvmf|srp_daemon|restart-resolved|dgx-|dgxstation|cloud-|apport|brltty|debug-shell|console-getty|dnsmasq|iscsid|kdump|open-iscsi|open-vm|openvpn|pollinate|quota|rpcbind|rsync|rtkit|samba|setup-oem|speech|switcheroo|systemd-pcrlock|systemd-confext|systemd-sysext|systemd-time-wait|systemd-boot|systemd-network|ua-reboot|ubuntu-advantage|upower|vgauth|wpa_supplicant|accounts-daemon|ipmievd|nftables|nmbd|smbd|saned|hwclock|cryptdisks|multipath-tools-boot|nfs-common|^ssh$|^sudo$|screen-cleanup|x11-common|alsa-utils|nvidia-remove-gnome|nvidia-desktop-default|nvidia-dgx-sol|nvidia-cdi-refresh|nvidia-suspend-then|fwupd|irqbalance|kerneloops|motd-news|ondemand|pppd-dns|thermald|udisks2|unattended-upgrades|whoopsie|plymouth)'

ssh "$SOURCE_HOST" "systemctl list-unit-files --type=service --state=enabled --no-pager" \
    | awk '/\.service/ { print $1 }' \
    | sed 's/\.service$//' \
    | awk -v re="$SERVICE_EXCLUDE" '$0 !~ re' \
    | sort > "$CAPTURE_DIR/services_enabled.txt"

ssh "$SOURCE_HOST" "systemctl list-unit-files --type=service --state=disabled --no-pager" \
    | awk '/\.service/ { print $1 }' \
    | sed 's/\.service$//' \
    | awk -v re="$SERVICE_EXCLUDE" '$0 !~ re' \
    | sort > "$CAPTURE_DIR/services_disabled.txt"

ssh "$SOURCE_HOST" "systemctl list-unit-files --type=service --state=masked --no-pager" \
    | awk '/\.service/ { print $1 }' \
    | sed 's/\.service$//' \
    | awk -v re="$SERVICE_EXCLUDE" '$0 !~ re' \
    | sort > "$CAPTURE_DIR/services_masked.txt"

echo "  Enabled: $(wc -l < "$CAPTURE_DIR/services_enabled.txt"), Disabled: $(wc -l < "$CAPTURE_DIR/services_disabled.txt"), Masked: $(wc -l < "$CAPTURE_DIR/services_masked.txt")"

# ============================================================
# 3. Capture user groups
# ============================================================
echo "--- Capturing user groups ---"
# shellcheck disable=SC2029
USER_GROUPS=$(ssh "$SOURCE_HOST" "id -nG '$MANAGED_USER'")
echo "  $MANAGED_USER groups: $USER_GROUPS"

# ============================================================
# 4. Capture config files
# ============================================================
echo "--- Capturing config files ---"

# Sysctl
while IFS= read -r f; do
    scp "$SOURCE_HOST:$f" "$CAPTURE_DIR/config_files/etc_sysctl.d/"
done < <(ssh "$SOURCE_HOST" "find /etc/sysctl.d -maxdepth 1 -type f -name '*.conf' -print")

# Modprobe (all .conf files)
while IFS= read -r f; do
    scp "$SOURCE_HOST:$f" "$CAPTURE_DIR/config_files/etc_modprobe.d/"
done < <(ssh "$SOURCE_HOST" "find /etc/modprobe.d -maxdepth 1 -type f -name '*.conf' -print")

# NVIDIA container runtime
if ssh "$SOURCE_HOST" "test -f /etc/nvidia-container-runtime/config.toml"; then
    scp "$SOURCE_HOST":/etc/nvidia-container-runtime/config.toml "$CAPTURE_DIR/config_files/etc_nvidia-container-runtime/"
else
    echo "  WARN: nvidia-container-runtime config not found"
fi

# Containerd
if ssh "$SOURCE_HOST" "test -f /etc/containerd/config.toml"; then
    scp "$SOURCE_HOST":/etc/containerd/config.toml "$CAPTURE_DIR/config_files/etc_containerd/"
else
    echo "  WARN: containerd config not found"
fi

# SSH hardening (all .conf in sshd_config.d)
while IFS= read -r f; do
    scp "$SOURCE_HOST:$f" "$CAPTURE_DIR/config_files/etc_ssh_sshd_config.d/"
done < <(ssh "$SOURCE_HOST" "find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf' -print")

# NetworkManager
while IFS= read -r f; do
    scp "$SOURCE_HOST:$f" "$CAPTURE_DIR/config_files/etc_NetworkManager_conf.d/"
done < <(ssh "$SOURCE_HOST" "find /etc/NetworkManager/conf.d -maxdepth 1 -type f -name '*.conf' -print")

# GRUB defaults
if ssh "$SOURCE_HOST" "test -f /etc/default/grub"; then
    scp "$SOURCE_HOST":/etc/default/grub "$CAPTURE_DIR/config_files/etc_default/"
else
    echo "  WARN: grub defaults not found"
fi

echo "  Config files captured to $CAPTURE_DIR/config_files/"

# ============================================================
# 5. Generate group_vars from captured state
# ============================================================
echo "--- Generating inventory/group_vars/dgx_spark.yml ---"

cat > "$GROUP_VARS" << HEADER
---
# ============================================================
# DGX Spark Shared Desired State
# Source: $SOURCE_HOST | Captured: $TIMESTAMP
# Re-generate with: make capture
# ============================================================

HEADER

# User groups
{
    echo "managed_user: $MANAGED_USER"
    echo ""
    echo "captured_user_groups:"
    echo "  $MANAGED_USER:"
    for g in $USER_GROUPS; do
        echo "    - $g"
    done
    echo ""

    echo "captured_packages:"
    while IFS= read -r pkg; do
        echo "  - $pkg"
    done < "$CAPTURE_DIR/packages_filtered.txt"
    echo ""

    echo "captured_services_enabled:"
    while IFS= read -r svc; do
        echo "  - $svc"
    done < "$CAPTURE_DIR/services_enabled.txt"
    echo ""
    echo "captured_services_disabled:"
    while IFS= read -r svc; do
        echo "  - $svc"
    done < "$CAPTURE_DIR/services_disabled.txt"
    echo ""
    echo "captured_services_masked:"
    while IFS= read -r svc; do
        echo "  - $svc"
    done < "$CAPTURE_DIR/services_masked.txt"
    echo ""

    cat << 'PURGE'
# Curated list of bloat packages to remove from targets.
# Review before running 'make apply'.
packages_to_purge:
  - cloud-init
  - cloud-guest-utils
  - samba
  - samba-common
  - samba-common-bin
  - gnome-remote-desktop
  - switcheroo-control
  - open-vm-tools
  - open-iscsi
  - kdump-tools
PURGE
} >> "$GROUP_VARS"

echo ""
echo "=== Capture complete ==="
echo "Review: $GROUP_VARS"
echo "Config files: $CAPTURE_DIR/config_files/"
echo ""
echo "Next steps:"
echo "  make diff          # Compare source and target state"
echo "  make apply-check   # Dry run with diff output"
echo "  make apply         # Apply to the sync target"
