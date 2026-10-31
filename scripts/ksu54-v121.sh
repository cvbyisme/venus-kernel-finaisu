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
  echo "  skipped (already applied)"
fi

echo "=== [v121] step 2: 5.4 shims for feature/sucompat.c ==="
python3 - "$SUDIR" <<'PYEOF'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'feature', 'sucompat.c')
if not os.path.exists(path):
    print('  ERROR: sucompat.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()

# --- 2a: linux/pgtable.h does not exist before 5.8 ---
old = '#include <linux/pgtable.h>'
if old in src:
    src = src.replace(old, '#include <asm/pgtable.h> /* v121: linux/pgtable.h split out in 5.8 */', 1)
    print('  patched: pgtable.h -> asm/pgtable.h')
elif 'v121: linux/pgtable.h' in src:
    print('  skipped: pgtable already patched')
else:
    print('  WARN: pgtable anchor not found')

# --- 2b: strncpy_from_user_nofault() only exists since 5.7 ---
marker = 'v121_strncpy_nofault'
if marker in src:
    print('  skipped: strncpy shim already present')
else:
    shim = (
        '/* v121_strncpy_nofault: strncpy_from_user_nofault() only exists since 5.7 */\n'
        '#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 7, 0))\n'
        'static inline long ksu_strncpy_from_user_nofault(char *dst, const void __user *src, long count)\n'
        '{\n'
        '    long ret = 0;\n'
        '    if (unlikely(count <= 0))\n'
        '        return 0;\n'
        '    pagefault_disable();\n'
        '    ret = strncpy_from_user(dst, src, count);\n'
        '    pagefault_enable();\n'
        '    return ret;\n'
        '}\n'
        '#else\n'
        '#define ksu_strncpy_from_user_nofault(dst, src, count) strncpy_from_user_nofault(dst, src, count)\n'
        '#endif\n'
    )
    # insert after the last #include of the first include block
    anchor = '#include "util.h"\n'
    if anchor not in src:
        anchor = '#include <linux/ptrace.h>\n'
    if anchor not in src:
        print('  ERROR: no anchor for shim insertion'); sys.exit(1)
    src = src.replace(anchor, anchor + '\n' + shim, 1)
    # rewrite call sites
    n = src.count('strncpy_from_user_nofault(path,')
    src = src.replace('strncpy_from_user_nofault(path,', 'ksu_strncpy_from_user_nofault(path,')
    print('  patched: strncpy shim added, %d call sites rewritten' % n)

open(path, 'w', encoding='utf-8').write(src)
PYEOF

echo "=== [v121] result ==="
grep -n 'v121_force_no_preinit\|KSU_NO_PREINIT' "$SUDIR/Kbuild" | head -3
grep -n 'v121:\|v121_strncpy\|ksu_strncpy_from_user_nofault' "$SUDIR/feature/sucompat.c" | head -8
echo "=== [v121] done ==="
