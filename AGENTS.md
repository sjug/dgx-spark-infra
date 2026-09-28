# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other agentic
coding tools when working in this repository. `CLAUDE.md` is a symlink to this
file.

## What this repo is

Ansible project for managing a small fleet of NVIDIA DGX Spark machines
(Ubuntu 24.04, aarch64). The core model: capture the state of a
source-of-truth node into variable files, then converge other nodes toward
that state. Separate playbooks handle new-host cleanup/minimization and
routine maintenance (ML cache cleaning, reboots).

## Commands

```bash
make validate            # syntax-check + ansible-lint + yamllint + shellcheck + git whitespace
make lint-ansible        # run one linter in isolation (also: lint-yaml, lint-shell, lint-git)
make ping                # Ansible connectivity test to the dgx_spark group

make capture             # capture source node state -> group_vars + captured_state/
make diff                # quick SSH-based diff between two machines (no Ansible)

make apply-check         # dry-run full sync (--check --diff)
make apply               # full sync to sync_targets
make apply-packages      # tag-scoped sync; also: apply-services, apply-users, apply-configs

make cleanup-check       # dry-run snap + systemd cleanup on cleanup_targets
make cleanup
make minimal-packages-check  # dry-run tool install + podman setup on package_targets
make minimal-packages
make podman-upgrade-check    # dry-run upgrade of installed Podman PPA packages only
make podman-upgrade          # (PODMAN_TARGET=a,b; defaults to PACKAGE_TARGET)
make upgrade-check       # dry-run full apt upgrade (UPGRADE_TARGET=a,b)
make upgrade             # full upgrade; reboot into the newest kernel only if needed
make boot-kernel-check KERNEL=6.17.0-1032-nvidia  # dry-run a one-shot kernel boot
make boot-kernel KERNEL=6.17.0-1032-nvidia        # boot a kernel once; next reboot returns to the newest
make cache-clean-check   # dry-run ML cache cleanup + kernel cache drop
make cache-clean
make reboot              # cache clean + reboot + settle (skip caches: ANSIBLE_OPTS="-e clean_caches=false")
```

There is no test suite; `make validate` is the gate and is what CI runs
(`.github/workflows/validate.yml`). Every mutating target has a `-check`
dry-run twin; run it first.

Local defaults (hosts, managed user) come from `.env.mk` (gitignored; see
`.env.mk.example`). Makefile variables `TARGET`, `CLEANUP_TARGET`,
`PACKAGE_TARGET`, `MAINTENANCE_TARGET`, `SOURCE_HOST`, `DIFF_HOST_A/B`,
`MANAGED_USER` override per invocation.

Privilege escalation: `ansible.cfg` sets `become_ask_pass = True`, so every
apply-style run interactively prompts for the sudo password. Agents cannot
answer that prompt; ask the user to run apply/cleanup/reboot targets, or
stick to `-check` runs and read-only SSH commands.

## Architecture

**Capture → apply pipeline.** `scripts/capture.sh` SSHes to the
source-of-truth host, extracts manually-installed packages, service states,
user groups, and config files, filters them through exclusion regexes (base
system, DGX-OTA-managed packages, systemd internals), and generates
`inventory/group_vars/dgx_spark.yml` plus `captured_state/config_files/`.
The `dgx_spark_sync` role then applies that as desired state. The group_vars
file is generated; change the filters or the curated `packages_to_purge`
list in `capture.sh`, not in the generated file.

**Inventory groups drive targeting.** `inventory/hosts.yml` (local, not
committed) defines: `dgx_spark` (the synced pair, with `peer_*`/`ib_peer_*`
host vars used for /etc/hosts and InfiniBand peering), `source_of_truth`,
`sync_targets`, and `cleanup_targets`/`package_targets` (new hosts being
minimized). Playbooks take `-e target=<group>`; the Makefile wires each
target variable to the right playbook.

**Roles.** Every role pulls in `dgx_spark_platform_check` as a meta
dependency, which asserts the host is Ubuntu 24.04 aarch64 before anything
runs. `dgx_spark_sync` is the big one (packages/services/user
groups/config-dir sync with per-area tags); `snap_cleanup` +
`systemd_cleanup` strip new hosts; `dgx_spark_minimal_packages` installs a
small tool set and Podman from a pinned PPA (origin verified via
`scripts/podman-origin.sh`). Its `podman_upgrade` tag upgrades only the
installed packages the PPA publishes: every PPA package is pinned to the
PPA at 990, and `scripts/ppa-packages.sh` fails the run on held packages
or on versions offered by any other repo. Upgrades restart only root-level
podman units, so running rootless containers keep running; restart them
afterwards per tensor-parallel group. `dgx_spark_maintenance` implements
`cache-clean` and `reboot` via role vars, and refuses to run while podman
pods are running. It also implements `upgrade` and `boot-kernel`: a normal
full apt upgrade with no GRUB pins or apt holds (it deletes the old
hand-made `zz-local-kernel-default.cfg` pin), refusing while any root or
rootless container runs, allowing only old per-version kernel packages to
be removed, and keeping the podman stack on the PPA. Before a reboot it
checks the kernel GRUB will boot: NVIDIA module version matches the
installed driver, initramfs present, required boot options (`kho=off` for
7.x, from NVIDIA's `nvidia-spark-grub-kho` hotfix). `scripts/boot-kernel.sh
verify` reads the generated `grub.cfg` as the final gate and fails closed
on anything it cannot model. After the reboot it verifies kernel, driver,
command line and `nvidia-smi`. `boot-kernel` uses `grub-reboot` only, so a
fallback kernel never becomes the default.

**Convergence semantics.** Captured config directories are authoritative
(extra files on the target are deleted); package sync is additive (nothing
removed unless listed in `packages_to_purge`); purges are skipped and
reported if they would drag along packages not allow-listed in
`packages_to_purge_allow_extra`.

## Conventions

- **Sanitization:** committed files use example names (`source-node`,
  `target-node`) and documentation IP ranges (`192.0.2.x`, `198.51.100.x`).
  Real hostnames, IPs, and captured state live only in gitignored files
  (`inventory/hosts.yml`, `inventory/group_vars/dgx_spark.yml`,
  `captured_state/`, `docs/`, `logs/`, `.env.mk`). Never write real fleet
  hostnames or IPs into committed files, including this one.
- **Podman, not Docker:** the fleet is migrating off docker; treat leftover
  docker wiring as removable, not something to preserve.
- **Tags need static imports:** `dgx_spark_sync/tasks/main.yml` uses
  `import_tasks` (not `include_tasks`) so `--tags packages` etc. reach the
  tasks inside the imported files. Keep new task files consistent with this.
- **Adding a synced config file:** add a `capture_conf_dir`/`capture_file`
  call in `scripts/capture.sh`, wire it into `dgx_spark_sync` (reuse
  `config_dir_sync.yml` for `*.conf` directories), add a handler if a
  service must restart, then `make capture && make apply-check`.
