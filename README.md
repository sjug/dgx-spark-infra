# dgx-spark-infra

Ansible project for keeping two DGX Spark machines in sync.

## Quick Start

```bash
# 1. Copy the example inventory and customize it locally
cp inventory/hosts.example.yml inventory/hosts.yml

# 2. Run local validation
make validate

# 3. Test connectivity
make ping

# 4. Capture the source node's current state
make capture SOURCE_HOST=source-node MANAGED_USER=admin

# 5. Review what would change on the target node
make apply-check

# 6. Review systemd-only cleanup for new nodes
make cleanup-check

# 7. Review minimal package install for new nodes
make minimal-packages-check

# 8. Clean ML caches and drop filesystem caches without rebooting
make cache-clean

# 9. Apply changes
make apply
```

## Architecture

- `source-node` and `target-node` in [inventory/hosts.example.yml](inventory/hosts.example.yml)
  are sanitized example names.
- The example inventory uses the documentation-only IP ranges `192.0.2.0/24`
  and `198.51.100.0/24`.
- Real hostnames, IPs, and generated captured state should stay in ignored
  local files such as `inventory/hosts.yml`,
  `inventory/group_vars/dgx_spark.yml`, `captured_state/`, and `logs/`.

`scripts/capture.sh` connects to the source node, extracts
packages/services/groups/configs, and writes them into
`inventory/group_vars/dgx_spark.yml` plus `captured_state/config_files/`.

Playbooks apply that captured state to any target machine.

Validation is available locally through `make validate` and in CI through
`.github/workflows/validate.yml`.

## What Gets Synced

| Category | Details |
|----------|---------|
| APT Packages | Additive install of user-installed packages (filtered: no base system, no OTA-managed NVIDIA pkgs) |
| Bloat Removal | Curated list of packages to purge (cloud-init, samba, cups, etc.) |
| Snap Cleanup | Remove pre-installed snaps before snapd is disabled |
| Systemd Services | Enabled/disabled/masked state (filtered: no systemd internals) |
| User Groups | Group memberships for the managed admin user |
| Sysctl | Authoritative sync of captured `/etc/sysctl.d/*.conf` files |
| Modprobe | Authoritative sync of captured `/etc/modprobe.d/*.conf` files |
| NVIDIA Runtime | Container runtime config |
| SSH | Authoritative sync of captured `/etc/ssh/sshd_config.d/*.conf` files |
| NetworkManager | Authoritative sync of captured `/etc/NetworkManager/conf.d/*.conf` files |
| /etc/hosts | Managed peer-entry block appended to the existing file |
| GRUB | Kernel command line parameters |

## Commands

```
make help               # Show all targets
make validate           # Run syntax + lint + whitespace checks
make syntax-check       # Run Ansible syntax validation
make lint-ansible       # Run ansible-lint
make lint-yaml          # Run yamllint
make lint-shell         # Run shellcheck on scripts
make lint-git           # Check Git whitespace errors
make capture            # Capture the source node's state
make diff               # Quick SSH diff between machines
make ping               # Test Ansible connectivity
make apply-check        # Preview all changes (dry run)
make apply              # Apply all changes
make cleanup-check      # Preview snap and systemd cleanup
make cleanup            # Apply snap and systemd cleanup
make minimal-packages-check # Preview minimal package install only
make minimal-packages   # Install minimal new-host packages only
make cache-clean-check  # Preview ML cache cleanup and kernel cache flush
make cache-clean        # Clean ML caches and drop kernel filesystem caches
make apply-packages     # Sync packages only
make apply-services     # Sync services only
make apply-users        # Sync user groups only
make apply-configs      # Sync config files only
make reboot             # Clean ML caches, reboot nodes, then drop kernel caches
make roce-lossless-check # Preview RoCE lossless host config
make roce-lossless      # Apply RoCE lossless host config
make capture SOURCE_HOST=source-node MANAGED_USER=admin
```

Validation requires `ansible-core`, `ansible-lint`, `yamllint`, and
`shellcheck` to be installed locally.

## Overrides

- Copy [.env.mk.example](.env.mk.example)
  to `.env.mk` and set your local defaults there. `Makefile` loads it automatically.
- Override the SSH source alias with `SOURCE_HOST=...` for `make capture`.
- Override the cleanup inventory group with `CLEANUP_TARGET=...` for
  `make cleanup-check` and `make cleanup`.
- Override the minimal package inventory group with `PACKAGE_TARGET=...` for
  `make minimal-packages-check` and `make minimal-packages`.
- Override the maintenance inventory group with `MAINTENANCE_TARGET=...` for
  `make cache-clean-check` and `make cache-clean`.
- Override the connectivity test group with `PING_TARGET=...` for `make ping`.
- Override the RoCE inventory group with `ROCE_TARGET=...` for
  `make roce-lossless-check` and `make roce-lossless`.
- Override the SSH config file used by `make diff` with `DGX_SSH_CONFIG=...`.
  By default, `make diff` honors normal SSH config lookup.
- Override the managed account with `MANAGED_USER=...` for `make capture`
  and `make diff`.
- Override `ANSIBLE_REMOTE_TEMP=...` if a previous run left a remote temp
  directory with incompatible ownership. The default is `/tmp`, letting Ansible
  create per-task secure temporary subdirectories.

## Convergence Notes

- Captured config directories are authoritative. Extra files in the synced
  target directories are removed if they are not present in `captured_state/`.
- Package sync is intentionally additive. Extra packages on the target are not
  removed unless they appear in `packages_to_purge`.
- Curated purge safety is enforced per package. If purging a requested package
  would also remove additional packages, that purge is skipped and reported
  unless the collateral removals are listed in `packages_to_purge_allow_extra`.
- Tailscale repository selection is based on the target host's Ubuntu codename
  and is limited to the explicitly supported codenames defined in
  `roles/dgx_spark_sync/defaults/main.yml`.

## RoCE Lossless Host Config

`make roce-lossless` deploys `/usr/local/sbin/roce-lossless.sh` and its
oneshot systemd unit to the `roce_hosts` group. The unit configures
DSCP-trust, PFC on priority 3, and the lossless receive buffer on each
ConnectX twin at boot, matching the switch-side QoS. Applying the role only
proves the local config; the on-the-wire classification gate lives in
`scripts/roce-tests/` (local-only, not committed — the scripts embed real
fleet hostnames).

## Reboot

`make cache-clean` safely cleans cache state without rebooting. The playbook:

1. Asserts no podman pods are running (fails if any are)
2. Cleans ML compilation caches
3. Syncs filesystems
4. Drops kernel filesystem caches

The cleaned ML cache paths are `~/.cache/vllm`, `~/.cache/flashinfer`, and
`~/.triton`.

`make reboot` uses the same maintenance role, but enables rebooting:

1. Asserts no podman pods are running (fails if any are)
2. Cleans ML compilation caches by default
3. Reboots and waits 60s for services to settle
4. Syncs and drops kernel filesystem caches

To reboot without purging ML compilation caches:

```bash
make reboot ANSIBLE_OPTS="-e clean_caches=false"
```

These caches store JIT-compiled CUDA/Triton/FlashInfer kernels. Clearing them
forces recompilation on next startup, which adds several minutes but can
resolve issues caused by stale compiled artifacts.

## Adding New Config Files

1. Add a `capture_conf_dir` (or `capture_file`) call to `scripts/capture.sh`
2. For a `*.conf` directory, import `config_dir_sync.yml` from
   `roles/dgx_spark_sync/tasks/main.yml` with the directory vars; for anything
   else add a task file under `roles/dgx_spark_sync/tasks/`
3. Add a handler in `roles/dgx_spark_sync/handlers/main.yml` if a service needs restarting
4. Re-run `make capture && make apply-check`
