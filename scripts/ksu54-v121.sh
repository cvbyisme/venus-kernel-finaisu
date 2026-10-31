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


echo "=== [v121] step 3: 5.4 shims for hook/arm64/patch_memory.c ==="
python3 - "$SUDIR" <<'PYEOF3'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'hook', 'arm64', 'patch_memory.c')
if not os.path.exists(path):
    print('  ERROR: patch_memory.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()

if 'v121_patchmem_shim' in src:
    print('  skipped: patch_memory.c already patched'); sys.exit(0)

# 1) __p4d_to_phys does not exist on 5.4 (it appeared in 5.5)
src = src.replace('__p4d_to_phys(*p4d)', 'ksu_p4d_to_phys_54(*p4d)', 1)

# 2) copy_to_kernel_nofault appeared in 5.8
n = src.count('copy_to_kernel_nofault(')
src = src.replace('ret = (int)copy_to_kernel_nofault(map, src, len);',
                  'ret = (int)ksu_copy_to_kernel_nofault(map, src, len);', 1)

shim = (
    '\n/* v121_patchmem_shim: helpers that only exist on newer kernels */\n'
    '#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 5, 0))\n'
    '#define ksu_p4d_to_phys_54(p4d) __pa(p4d_val(p4d) & PHYS_MASK)\n'
    '#else\n'
    '#define ksu_p4d_to_phys_54(p4d) __p4d_to_phys(p4d)\n'
    '#endif\n'
    '\n'
    '#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0))\n'
    'static inline long ksu_copy_to_kernel_nofault(void *dst, const void *src, size_t size)\n'
    '{\n'
    '    memcpy(dst, src, size);\n'
    '    return 0;\n'
    '}\n'
    '#else\n'
    '#define ksu_copy_to_kernel_nofault(dst, src, size) copy_to_kernel_nofault(dst, src, size)\n'
    '#endif\n'
)

anchor = '#include "asm-generic/fixmap.h"\n'
if anchor not in src:
    print('  ERROR: anchor not found'); sys.exit(1)
src = src.replace(anchor, anchor + shim, 1)

open(path, 'w', encoding='utf-8').write(src)
print('  patched: patch_memory.c (p4d_to_phys + copy_to_kernel_nofault shims)')
PYEOF3


echo "=== [v121] step 4: 5.4 shims for sulog/event.c ==="
python3 - "$SUDIR" <<'PYEOF4'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'sulog', 'event.c')
if not os.path.exists(path):
    print('  ERROR: sulog/event.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()
if 'v121_minmax_shim' in src:
    print('  skipped: minmax already patched'); sys.exit(0)
old = '#include <linux/minmax.h>'
if old not in src:
    print('  WARN: linux/minmax.h anchor not found'); sys.exit(0)
new = ('/* v121_minmax_shim: linux/minmax.h split out in 5.11; 5.4 has these in linux/kernel.h */\n'
       '#if (LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0))\n'
       + old + '\n'
       '#else\n'
       '#include <linux/kernel.h>\n'
       '#endif')
src = src.replace(old, new, 1)
open(path, 'w', encoding='utf-8').write(src)
print('  patched: sulog/event.c minmax include guarded')
PYEOF4


echo "=== [v121] step 5: 5.4 stub for infra/seccomp_cache.c ==="
python3 - "$SUDIR" <<'PYEOF5'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'infra', 'seccomp_cache.c')
if not os.path.exists(path):
    print('  ERROR: infra/seccomp_cache.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()
if 'v121_seccomp_stub' in src:
    print('  skipped: seccomp stub already applied'); sys.exit(0)

stub = '''/* v121_seccomp_stub: Linux 5.4 has no seccomp bitmap cache (added in 5.9).
 * On 5.4 every syscall goes through the full seccomp filter, so there is
 * nothing to pre-populate. These become no-ops: correct, just marginally
 * slower than 5.9+ which caches the allow bitmask.
 */
#include <linux/version.h>

#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0))

#include <linux/seccomp.h>
#include "infra/seccomp_cache.h"

void ksu_seccomp_clear_cache(struct seccomp_filter *filter, int nr)
{
    (void)filter;
    (void)nr;
}

void ksu_seccomp_allow_cache(struct seccomp_filter *filter, int nr)
{
    (void)filter;
    (void)nr;
}

#else
'''

# keep original body for 5.9+
src = stub + src + '\n#endif\n'
open(path, 'w', encoding='utf-8').write(src)
print('  patched: seccomp_cache.c wrapped in 5.9 guard with no-op stubs')
PYEOF5


# --- step 6: manager/pkg_observer.c (task_work flags + fsnotify_ops ABI) ---
cat > /tmp/shim6.txt <<'SHIM6EOF'

/* v121_pkgobs_shim: 5.4 compat for task_work flags and fsnotify_ops */
#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0))
static inline int ksu_task_work_add_54(struct task_struct *t, struct callback_head *cb)
{
    return task_work_add(t, cb, true);
}
#endif

#if (LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0))
#define ksu_FSNOTIFY_OPS_FIELD handle_event
#define ksu_FSNOTIFY_HANDLER_54 ksu_handle_event_54
static int ksu_handle_event_54(struct fsnotify_group *group, struct inode *inode, u32 mask,
                               const void *data, int data_type, const struct qstr *file_name,
                               u32 cookie, struct fsnotify_iter_info *iter_info)
{
    return ksu_handle_inode_event(NULL, mask, inode, NULL, file_name, cookie);
}
#else
#define ksu_FSNOTIFY_OPS_FIELD handle_inode_event
#define ksu_FSNOTIFY_HANDLER_54 ksu_handle_inode_event
#endif
SHIM6EOF
cat > /tmp/step6.py <<'PYEOF6'
import sys, os
sudir = sys.argv[1]
path = os.path.join(sudir, 'manager', 'pkg_observer.c')
if not os.path.exists(path):
    print('  ERROR: manager/pkg_observer.c not found'); sys.exit(1)
src = open(path, encoding='utf-8').read()
if 'v121_pkgobs_shim' in src:
    print('  skipped: already patched'); sys.exit(0)

# 1) TWA_RESUME -> 5.4 shim (task_work_add 第三参数是 bool)
old_twa = 'if (!task_work_add(current, cb, TWA_RESUME))'
if old_twa in src:
    src = src.replace(old_twa, 'if (!ksu_task_work_add_54(current, cb))', 1)
else:
    print('  ERROR: task_work_add anchor not found'); sys.exit(1)

# 2) fsnotify_ops 字段名与 handler -> 宏映射
old_ops = '    .handle_inode_event = ksu_handle_inode_event,'
if old_ops in src:
    src = src.replace(old_ops, '    ksu_FSNOTIFY_OPS_FIELD = ksu_FSNOTIFY_HANDLER_54,', 1)
else:
    print('  ERROR: fsnotify_ops anchor not found'); sys.exit(1)

# 3) shim 必须插在 ksu_handle_inode_event 定义之后（否则前向引用）
shim = open('/tmp/shim6.txt').read()
anchor = '''static const struct fsnotify_ops ksu_ops = {'''
if anchor not in src:
    print('  ERROR: shim anchor not found'); sys.exit(1)
src = src.replace(anchor, shim + '\n' + anchor, 1)

open(path, 'w', encoding='utf-8').write(src)
print('  patched: pkg_observer.c (task_work + fsnotify_ops shims)')
PYEOF6
python3 /tmp/step6.py "$SUDIR" || echo "[v121] WARN: step6 failed"
echo "=== [v121] result ==="
grep -n 'v121_force_no_preinit\|KSU_NO_PREINIT' "$SUDIR/Kbuild" | head -3
grep -n 'v121:\|v121_strncpy\|ksu_strncpy_from_user_nofault' "$SUDIR/feature/sucompat.c" | head -8
grep -n 'v121_seccomp_stub' "$SUDIR/infra/seccomp_cache.c" | head -2
grep -n 'v121_minmax_shim' "$SUDIR/sulog/event.c" | head -2
grep -n 'v121_pkgobs_shim\|ksu_task_work_add_54\|ksu_FSNOTIFY' "$SUDIR/manager/pkg_observer.c" | head -6
grep -n 'v121_patchmem_shim\|ksu_p4d_to_phys_54\|ksu_copy_to_kernel_nofault' "$SUDIR/hook/arm64/patch_memory.c" | head -6
echo "=== [v121] done ==="
