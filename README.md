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

# 6. Apply changes
make apply
```

## Architecture

- `source-node` and `target-node` in [inventory/hosts.example.yml](/home/jugs/git/dgx-spark-infra/inventory/hosts.example.yml)
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
| Systemd Services | Enabled/disabled/masked state (filtered: no systemd internals) |
| User Groups | Group memberships for the managed admin user |
| Sysctl | Authoritative sync of captured `/etc/sysctl.d/*.conf` files |
| Modprobe | Authoritative sync of captured `/etc/modprobe.d/*.conf` files |
| NVIDIA Runtime | Container runtime config |
| Containerd | Container daemon config |
| SSH | Authoritative sync of captured `/etc/ssh/sshd_config.d/*.conf` files |
| NetworkManager | Authoritative sync of captured `/etc/NetworkManager/conf.d/*.conf` files |
| /etc/hosts | Managed peer-entry block appended to the existing file |
| GRUB | Kernel command line parameters |

## Commands

```
make help               # Show all targets
make validate           # Run syntax + lint checks
make syntax-check       # Run Ansible syntax validation
make lint-ansible       # Run ansible-lint
make lint-yaml          # Run yamllint
make lint-shell         # Run shellcheck on scripts
make capture            # Capture the source node's state
make diff               # Quick SSH diff between machines
make ping               # Test Ansible connectivity
make apply-check        # Preview all changes (dry run)
make apply              # Apply all changes
make apply-packages     # Sync packages only
make apply-services     # Sync services only
make apply-users        # Sync user groups only
make apply-configs      # Sync config files only
make reboot              # Reboot nodes (asserts no running pods first)
make capture SOURCE_HOST=source-node MANAGED_USER=admin
```

Validation requires `ansible-core`, `ansible-lint`, `yamllint`, and
`shellcheck` to be installed locally.

## Overrides

- Copy [.env.mk.example](/home/jugs/git/dgx-spark-infra/.env.mk.example)
  to `.env.mk` and set your local defaults there. `Makefile` loads it automatically.
- Override the SSH source alias with `SOURCE_HOST=...` for `make capture`.
- Override the managed account with `MANAGED_USER=...` for `make capture`
  and `make diff`.

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

## Reboot

`make reboot` safely reboots all DGX Spark nodes. The playbook:

1. Asserts no podman pods are running (fails if any are)
2. Optionally cleans ML compilation caches
3. Reboots and waits 60s for services to settle
4. Drops filesystem caches

To also purge ML compilation caches (`~/.cache/vllm`, `~/.cache/flashinfer`,
`~/.triton`) before rebooting:

```bash
make reboot ANSIBLE_OPTS="-e clean_caches=true"
```

These caches store JIT-compiled CUDA/Triton/FlashInfer kernels. Clearing them
forces recompilation on next startup, which adds several minutes but can
resolve issues caused by stale compiled artifacts.

## Adding New Config Files

1. Add the `scp` line to `scripts/capture.sh`
2. Add a task in `roles/dgx_spark_sync/tasks/config_*.yml`
3. Add a handler in `roles/dgx_spark_sync/handlers/main.yml` if a service needs restarting
4. Re-run `make capture && make apply-check`
