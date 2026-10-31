#!/bin/bash
# Linux 5.4 compatibility shims for FinaSU v1.2.1 on venus (sm8350)
set -e
KDIR="$1"
[ -d "$KDIR" ] || { echo "usage: $0 <kernel-dir>"; exit 1; }
SUDIR="$KDIR/KernelSU/kernel"
[ -d "$SUDIR" ] || { echo "ERROR: $SUDIR missing"; exit 1; }

echo "=== [v121] step 1: force KSU_NO_PREINIT ==="
KB="$SUDIR/Kbuild"
if [ -f "$KB" ] && ! grep -q 'v121_force_no_preinit' "$KB"; then
  sed -i 's|^kernelsu-objs += preinit/preinit.o$|# v121_force_no_preinit: preinit disabled|' "$KB"
  sed -i 's|^kernelsu-objs += preinit/blob.o$||' "$KB"
  grep -q -- '-DKSU_NO_PREINIT' "$KB" || echo 'ccflags-y += -DKSU_NO_PREINIT' >> "$KB"
  echo "  patched: preinit objects removed, -DKSU_NO_PREINIT forced"
else
  echo "  skipped (already applied or Kbuild missing)"
fi

echo "=== [v121] step 2: guard <linux/pgtable.h> (split out in 5.8) ==="
python3 - "$SUDIR" <<'PYEOF'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'feature', 'sucompat.c')
if not os.path.exists(path):
    print('  ERROR: sucompat.c not found:', path); sys.exit(1)
src = open(path, encoding='utf-8').read()
marker = 'v121_guard_pgtable'
if marker in src:
    print('  skipped (already patched)'); sys.exit(0)
old = '#include <linux/pgtable.h>'
if old not in src:
    print('  ERROR: anchor <linux/pgtable.h> not found'); sys.exit(1)
new = ('#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 8, 0))\n'
       '/* v121_guard_pgtable: linux/pgtable.h split out in 5.8 */\n'
       + old + '\n'
       '#else\n'
       '#include <linux/mm.h>\n'
       '#include <asm/pgtable.h>\n'
       '#endif')
src = src.replace(old, new, 1)
open(path, 'w', encoding='utf-8').write(src)
print('  patched: sucompat.c pgtable include guarded')
PYEOF

echo "=== [v121] result ==="
grep -n 'v121_force_no_preinit\|KSU_NO_PREINIT' "$SUDIR/Kbuild" | head -3
grep -n 'v121_guard_pgtable' "$SUDIR/feature/sucompat.c" | head -2
echo "=== [v121] done ==="
