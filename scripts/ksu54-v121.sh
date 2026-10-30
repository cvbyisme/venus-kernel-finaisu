#!/bin/bash
# Linux 5.4 compatibility shims for FinaSU v1.2.1 on venus (sm8350)
set -e
KDIR="$1"
[ -d "$KDIR" ] || { echo "usage: $0 <kernel-dir>"; exit 1; }
SUDIR="$KDIR/KernelSU/kernel"
[ -d "$SUDIR" ] || { echo "ERROR: $SUDIR missing"; exit 1; }

echo "=== [v121] step 1: force KSU_NO_PREINIT (no uapi headers installed on 5.4 vendor) ==="
KB="$SUDIR/Kbuild"
if [ -f "$KB" ] && ! grep -q 'v121_force_no_preinit' "$KB"; then
  sed -i 's|^kernelsu-objs += preinit/preinit.o$|# v121_force_no_preinit: preinit disabled|' "$KB"
  sed -i 's|^kernelsu-objs += preinit/blob.o$||' "$KB"
  grep -q -- '-DKSU_NO_PREINIT' "$KB" || echo 'ccflags-y += -DKSU_NO_PREINIT' >> "$KB"
fi
grep -c 'v121_force_no_preinit' "$KB" || true

echo "=== [v121] step 2: drop zygote_next hook (does not exist on 5.4) ==="
grep -rn 'zygote_next' "$SUDIR" 2>/dev/null | head -5 || true

echo "=== [v121] done ==="
