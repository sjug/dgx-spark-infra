#!/usr/bin/env bash
# Work out which kernel GRUB boots next, and check it before a reboot.
#
#   newest [EXTRA_VERSION...]  newest installed kernel (GRUB's first entry).
#                              EXTRA versions count as installed, to predict
#                              an upgrade that has not run yet.
#   next [EXTRA_VERSION...]    kernel GRUB boots next, predicted from
#                              /etc/default/grub{,.d}, /boot and grubenv, the
#                              way grub-mkconfig builds the menu. Needs no root.
#   cmdline                    kernel options from /etc/default/grub{,.d}
#   entry VERSION              GRUB menu path for VERSION, for grub-reboot
#   verify VERSION [ARG...]    read the generated grub.cfg (root) and fail
#                              unless the entry GRUB boots next runs
#                              vmlinuz-VERSION with every ARG and loads
#                              initrd.img-VERSION. This is the
#                              check that gates a real reboot; next/cmdline
#                              are predictions for check mode.
#
# SKIP_CFG lists /etc/default/grub.d file names to ignore, to predict the
# result of removing them. Settings this script cannot model
# (GRUB_TOP_LEVEL, GRUB_DISABLE_SUBMENU, numeric defaults other than 0,
# Ubuntu's pending initrd-less boot fallback) make it exit 1, so callers
# fail closed rather than guess.
set -euo pipefail

boot_dir=${BOOT_DIR:-/boot}
grub_default_file=${GRUB_DEFAULT_FILE:-/etc/default/grub}
grub_default_dir=${GRUB_DEFAULT_DIR:-/etc/default/grub.d}
grubenv=${GRUBENV:-/boot/grub/grubenv}
grub_cfg=${GRUB_CFG:-/boot/grub/grub.cfg}
proc_cmdline=${PROC_CMDLINE:-/proc/cmdline}

usage() {
  echo "usage: $0 newest|next [EXTRA...] | cmdline | entry VERSION | verify VERSION [ARG...]" >&2
  exit 2
}

die() {
  echo "$*" >&2
  exit 1
}

# Source the GRUB defaults exactly as grub-mkconfig does.
load_defaults() {
  local f
  set +u
  # shellcheck disable=SC1090
  . "$grub_default_file"
  for f in "$grub_default_dir"/*.cfg; do
    [[ -e "$f" ]] || continue
    [[ " ${SKIP_CFG:-} " == *" ${f##*/} "* ]] && continue
    # shellcheck disable=SC1090
    . "$f"
  done
  set -u
  [[ -z "${GRUB_TOP_LEVEL:-}" ]] || die "GRUB_TOP_LEVEL is set; not supported"
  [[ "${GRUB_DISABLE_SUBMENU:-}" != true && "${GRUB_DISABLE_SUBMENU:-}" != y ]] ||
    die "GRUB_DISABLE_SUBMENU is set; not supported"
}

grubenv_get() {
  [[ -r "$grubenv" ]] || return 0
  sed -n "s/^$1=//p" "$grubenv" | head -n 1
}

# Ubuntu's 00_header replaces next_entry with prev_entry when a previous
# boot without an initramfs failed (initrdfail=1), so the entry we resolve
# would not be the one GRUB boots.
refuse_initrd_fallback() {
  [[ "$(grubenv_get initrdfail)" != 1 ]] ||
    die "GRUB initrd-less boot fallback is pending (initrdfail=1 in $grubenv); resolve it first"
}

newest() {
  local version
  version="$(
    {
      for f in "$boot_dir"/vmlinuz-*; do
        [[ -e "$f" ]] && echo "${f##*/vmlinuz-}"
      done
      printf '%s\n' "${extra[@]}"
    } | sed '/^$/d' | sort -V -r | head -n 1
  )"
  [[ -n "$version" ]] || die "no kernels found in $boot_dir"
  echo "$version"
}

# Map a GRUB default value (0, menu id path or title path) to a version.
resolve() {
  local value=$1 last
  case "$value" in
    "" | 0) newest ;;
    saved) resolve "$(grubenv_get saved_entry)" ;;
    *)
      last=${value##*>}
      if [[ "$last" =~ ^gnulinux-(.+)-advanced-[0-9A-Fa-f-]+$ ]]; then
        echo "${BASH_REMATCH[1]}"
      elif [[ "$last" =~ with\ Linux\ ([^ ]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
      elif [[ "$last" =~ ^gnulinux-simple- ]]; then
        newest
      else
        die "cannot resolve GRUB default '$value'"
      fi
      ;;
  esac
}

# Resolve the entry GRUB boots next from the generated grub.cfg and print
# "<kernel version> <kernel options>" for it.
grub_cfg_next() {
  [[ -r "$grub_cfg" ]] || die "cannot read $grub_cfg (needs root)"
  GRUBENV_NEXT="$(grubenv_get next_entry)" GRUBENV_SAVED="$(grubenv_get saved_entry)" \
    python3 - "$grub_cfg" <<'PY'
import os, re, shlex, sys

lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
root = {"kind": "submenu", "children": [], "title": "", "id": ""}
stack = [root]
current = None
default = None
for raw in lines:
    line = raw.strip()
    m = re.match(r'set default="([^"]*)"', line)
    if m and m.group(1) != "${next_entry}":
        default = m.group(1)
    m = re.match(r"(menuentry|submenu)\s+(.*)\{$", line)
    if m:
        words = shlex.split(m.group(2))
        ident = ""
        if "$menuentry_id_option" in words:
            ident = words[words.index("$menuentry_id_option") + 1]
        node = {"kind": m.group(1), "title": words[0], "id": ident,
                "children": [], "linux": None, "initrd": None,
                "if_depth": 0, "conditional": False}
        stack[-1]["children"].append(node)
        stack.append(node)
        continue
    if line.endswith("{"):
        stack.append({"kind": "block", "children": []})
        continue
    if line == "}":
        if len(stack) > 1:
            stack.pop()
        continue
    entry = next((n for n in reversed(stack) if n["kind"] == "menuentry"), None)
    if entry is None:
        continue
    # Walk statements in order so each linux/initrd is judged at the if-depth
    # where it actually runs (handles "if ...; then linux ...; fi" and
    # "initrd ...; fi" on one line).
    for stmt in (part.strip() for part in line.split(";")):
        stmt = re.sub(r"^(then|else)\s+", "", stmt)
        if re.match(r"(if|elif)\s", stmt):
            if stmt.startswith("if"):
                entry["if_depth"] += 1
            continue
        if stmt == "fi":
            entry["if_depth"] -= 1
            continue
        m = re.match(r"(linux|initrd)\s+(\S+)\s*(.*)$", stmt)
        if not m:
            continue
        if entry["if_depth"] > 0:
            entry["conditional"] = True
        if m.group(1) == "linux" and entry["linux"] is None:
            entry["linux"] = (m.group(2), m.group(3))
        elif m.group(1) == "initrd" and entry["initrd"] is None:
            entry["initrd"] = m.group(2)

value = os.environ.get("GRUBENV_NEXT") or default or "0"
if value == "${saved_entry}":
    value = os.environ.get("GRUBENV_SAVED") or "0"

node = root
for part in value.split(">"):
    items = [c for c in node["children"] if c["kind"] in ("menuentry", "submenu")]
    if part.isdigit():
        idx = int(part)
        if idx >= len(items):
            sys.exit(f"GRUB default '{value}' is out of range")
        node = items[idx]
    else:
        match = [c for c in items if part in (c["id"], c["title"])]
        if not match:
            sys.exit(f"GRUB default '{value}' matches no menu entry")
        node = match[0]
if node["kind"] == "menuentry" and node["conditional"]:
    sys.exit(f"GRUB default '{value}' has conditional linux/initrd commands; not supported")
if node["kind"] != "menuentry" or not node["linux"]:
    sys.exit(f"GRUB default '{value}' is not a bootable entry")
image, args = node["linux"]
m = re.search(r"vmlinuz-(\S+)$", image)
if not m:
    sys.exit(f"GRUB default '{value}' boots unexpected image {image}")
if not node["initrd"]:
    sys.exit(f"GRUB default '{value}' loads no initramfs")
print(m.group(1), node["initrd"], args)
PY
}

[[ $# -ge 1 ]] || usage
mode=$1
shift
extra=()

case "$mode" in
  newest)
    extra=("$@")
    newest
    ;;
  next)
    extra=("$@")
    refuse_initrd_fallback
    load_defaults
    next_entry="$(grubenv_get next_entry)"
    if [[ -n "$next_entry" ]]; then
      resolve "$next_entry"
    else
      [[ "${GRUB_DEFAULT:-0}" =~ ^[1-9] ]] && die "numeric GRUB_DEFAULT ${GRUB_DEFAULT} is not supported"
      resolve "${GRUB_DEFAULT:-0}"
    fi
    ;;
  cmdline)
    [[ $# -eq 0 ]] || usage
    load_defaults
    echo "${GRUB_CMDLINE_LINUX:-} ${GRUB_CMDLINE_LINUX_DEFAULT:-}" | xargs
    ;;
  entry)
    [[ $# -eq 1 ]] || usage
    version=$1
    load_defaults
    [[ -e "$boot_dir/vmlinuz-$version" ]] || die "kernel $version is not installed in $boot_dir"
    uuid="$(tr ' ' '\n' <"$proc_cmdline" | sed -n 's/^root=UUID=//p' | head -n 1)"
    [[ -n "$uuid" ]] || die "root is not mounted by UUID; cannot build the GRUB menu id"
    echo "gnulinux-advanced-$uuid>gnulinux-$version-advanced-$uuid"
    ;;
  verify)
    [[ $# -ge 1 ]] || usage
    version=$1
    shift
    refuse_initrd_fallback
    resolved="$(grub_cfg_next)"
    read -r booted initrd args <<<"$resolved"
    [[ "$initrd" == */initrd.img-"$version" ]] ||
      die "grub.cfg entry for $version loads initramfs '$initrd', not initrd.img-$version"
    [[ "$booted" == "$version" ]] || die "grub.cfg boots $booted next, not $version"
    for arg in "$@"; do
      [[ " $args " == *" $arg "* ]] || die "grub.cfg entry for $version lacks $arg"
    done
    echo "$booted $initrd $args"
    ;;
  *) usage ;;
esac
