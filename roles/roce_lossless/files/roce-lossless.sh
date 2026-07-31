#!/usr/bin/env bash
# RoCEv2 lossless host config for DGX Spark ConnectX-7, matching the CRS804 switch QoS.
#   RoCE data = DSCP 26 -> priority 3 (PFC lossless) ; CNP = DSCP 48 -> priority 6
#   DCQCN (CNP generation + rate reaction) is firmware-default-ON on ConnectX-7.
#   ToS 106 = (DSCP 26 << 2) | ECT(0)=0b10  -> DSCP 26 for switch TC3 classification
#             AND ECN-capable so the switch can mark CE. (104 = DSCP 26 + Not-ECT,
#             which only works if the NIC adds ECT itself - unproven on inbox driver.)
# Fails HARD on missing tools, missing RDMA device, apply error, or failed read-back.
# Idempotent; safe to re-run. Verifies trust=dscp and PFC-prio3 after applying.
set -euo pipefail

TOS=106                                   # DSCP 26 + ECT(0)
PFC_PRIO=3
PFC_MASK="0,0,0,1,0,0,0,0"                # PFC on priority 3 only
# RX buffer split (bytes): buffer0 = lossy prios, buffer1 = prio3 lossless.
# Maxed-out buffer1 (19872 + 2019744 = max_buffer_size 2039616): with switch-side
# PFC-rx disabled (rx=no, see README §3), the host buffer must absorb bursts for the
# FULL DCQCN reaction time (~50-500us), not just a PFC pause RTT. The default 525KB
# = only ~21us at line rate -> measured rx_prio3_discards under real vLLM load
# (2026-07-03). ~2MB ≈ 79us at full stall / ~316us at 50% drain.
BUF_SIZES="19872,2019744,0,0,0,0,0,0"
BUF1_MIN=1000000                          # read-back sanity floor (fw rounds the value)
# DGX Spark twins (f0 = switch-facing, f1 = back-to-back). RDMA device is derived
# at runtime from each netdev via ibdev2netdev - not hard-coded.
NDS=(enp1s0f0np0 enP2p1s0f0np0 enp1s0f1np1 enP2p1s0f1np1)

die(){ echo "roce-lossless: ERROR: $*" >&2; exit 1; }
for t in mlnx_qos cma_roce_tos ibdev2netdev; do
  command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found"
done

# Bounded wait for RDMA devices to appear (handles a boot-time race where this unit
# starts before mlx5 finishes creating the roce* devices). Up to ~30s, then proceed
# (the per-interface logic still fails hard if a present netdev has no RDMA device).
for _ in $(seq 1 30); do
  ibdev2netdev 2>/dev/null | grep -q ' ==> ' && break
  sleep 1
done

ok=0; fail=0; absent=0
for nd in "${NDS[@]}"; do
  if [ ! -e "/sys/class/net/$nd" ]; then
    echo "  skip $nd (netdev absent)"; absent=$((absent+1)); continue
  fi
  rd="$(ibdev2netdev 2>/dev/null | awk -v n="$nd" '$5==n{print $1; exit}')"
  if [ -z "$rd" ]; then
    echo "  FAIL $nd: no RDMA device found via ibdev2netdev"; fail=$((fail+1)); continue
  fi

  if ! mlnx_qos -i "$nd" --trust dscp --pfc "$PFC_MASK" >/dev/null 2>&1 \
     || ! mlnx_qos -i "$nd" --buffer_size "$BUF_SIZES"  >/dev/null 2>&1 \
     || ! mlnx_qos -i "$nd" --dscp2prio set,26,3 >/dev/null 2>&1 \
     || ! mlnx_qos -i "$nd" --dscp2prio set,48,6 >/dev/null 2>&1 \
     || ! cma_roce_tos -d "$rd" -t "$TOS"          >/dev/null 2>&1; then
    echo "  FAIL $nd ($rd): apply step failed"; fail=$((fail+1)); continue
  fi

  # read back and prove it took
  q="$(mlnx_qos -i "$nd" 2>/dev/null || true)"
  if ! echo "$q" | grep -qi "trust state: dscp"; then
    echo "  FAIL $nd: trust state is not 'dscp' after set"; fail=$((fail+1)); continue
  fi
  if ! echo "$q" | awk -v c=$((PFC_PRIO+2)) '
        /^[[:space:]]*enabled/{seen=1; if ($c!=1) bad=1}
        END{exit (seen && !bad)?0:1}'; then
    echo "  FAIL $nd: PFC priority $PFC_PRIO not enabled after set"; fail=$((fail+1)); continue
  fi
  # read back the lossless buffer (field 2 of "Receive buffer size (bytes): b0,b1,...")
  buf1="$(echo "$q" | sed -n 's/.*Receive buffer size (bytes): //p' | cut -d, -f2 | tr -cd '0-9')"
  if [ -z "$buf1" ] || [ "$buf1" -lt "$BUF1_MIN" ]; then
    echo "  FAIL $nd: prio$PFC_PRIO lossless buffer is '${buf1:-?}' (< $BUF1_MIN) after set"; fail=$((fail+1)); continue
  fi
  echo "  ok   $nd ($rd): trust=dscp pfc=prio$PFC_PRIO buf1=${buf1}B tos=$TOS(dscp26+ect0)"
  ok=$((ok+1))
done

echo "roce-lossless: configured=$ok failed=$fail absent=$absent"
[ "$fail" -eq 0 ] || die "$fail interface(s) failed to configure or verify"
[ "$ok"   -gt 0 ] || die "no interfaces were configured (all absent?)"
# NOTE: this proves trust=dscp + PFC-prio3 (and the dscp2prio map, visible once
# trust=dscp) LOCALLY. It does NOT prove the packets actually leave marked DSCP 26 on
# the wire (the inbox driver has no ToS read-back for cma_roce_tos). Host config is
# COMPLETE only after the end-to-end switch-counter gate passes:
# roce-tests/verify-classification.sh  (tx-queue3 must carry the RoCE load).
echo "roce-lossless: OK (local checks) — now run verify-classification.sh for the wire proof"
