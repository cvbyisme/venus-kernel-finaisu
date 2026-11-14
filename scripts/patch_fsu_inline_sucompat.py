#!/usr/bin/env python3
"""Patch FinaSU's Inline sucompat so that a plain `su` exec works from
non-privileged SELinux domains (e.g. Termux).

Background
----------
FinaSU v1.6.1 ships two sucompat implementations:

* syscall-hook flavour (kernel/feature/sucompat.c, used by Tracepoint):
  override_creds -> filp_open(KSUD_PATH) -> fd_install -> re-enter
  execveat(fd, "", AT_EMPTY_PATH, ...). The path lookup never happens with
  the caller's creds, so untrusted_app can run ksud.

* Inline flavour (kernel/extension/susfs.c, inline_handle_execveat): after
  escape_with_root_profile() it only memcpy()s KSUD_PATH over
  filename->name, letting __do_execve_file() do a path-based
  do_open_execat(). For untrusted_app/app_data_file that lookup is denied by
  SELinux (EACCES), and the shell reports "inaccessible or not found".
  It also matches only the literal "/system/bin/su", which does not exist
  when preinit is disabled.

What this patch does
--------------------
1. Match on basename == "su" instead of the hardcoded "/system/bin/su".
2. Execute via a kernel-opened fd: get_unused_fd_flags + override_creds +
   filp_open(KSUD_PATH, O_PATH) + fd_install, then rewrite
   *fd = tmp_fd, *flags |= AT_EMPTY_PATH, filename->name[0] = '\0'.
   This is the same trick as the syscall-hook flavour.
"""

import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'kernel/KernelSU/kernel/extension/susfs.c'
s = open(path, encoding='utf-8').read()

if 'inline_is_su_path' in s:
    print('already patched, skip')
    sys.exit(0)

old_inc = """#include <linux/cred.h>
#include <linux/err.h>
#include <linux/fs.h>"""
new_inc = """#include <linux/cred.h>
#include <linux/err.h>
#include <linux/fcntl.h>
#include <linux/file.h>
#include <linux/fs.h>"""
assert s.count(old_inc) == 1, 'include anchor not found'
s = s.replace(old_inc, new_inc)

anchor = """static bool inline_sucompat_allowed(void)
{"""
helper = """static bool inline_is_su_path(const char *path)
{
    const char *base;

    if (!path)
        return false;

    base = strrchr(path, '/');
    base = base ? base + 1 : path;

    return !strcmp(base, "su");
}

static bool inline_sucompat_allowed(void)
{"""
assert s.count(anchor) == 1, 'helper anchor not found'
s = s.replace(anchor, helper)

old_body = """    if (!inline_sucompat_allowed() || strcmp(path, SU_PATH) || !inline_ksud_exists())
        goto out;

    pending_sucompat = ksu_sulog_capture_sucompat_kernel(path, argv_user, GFP_KERNEL);
    pr_info("sucompat: direct exec su -> ksud\\n");
    ret = escape_with_root_profile();
    ksu_sulog_emit_pending(pending_sucompat, ret, GFP_KERNEL);
    pending_sucompat = NULL;
    if (ret)
        goto out;

    memcpy((void *)(*filename_ptr)->name, KSUD_PATH, sizeof(KSUD_PATH));
    return 0;
"""
new_body = """    if (!inline_sucompat_allowed() || !inline_is_su_path(path) || !inline_ksud_exists())
        goto out;

    pending_sucompat = ksu_sulog_capture_sucompat_kernel(path, argv_user, GFP_KERNEL);
    pr_info("sucompat: direct exec su -> ksud (fd)\\n");
    ret = escape_with_root_profile();
    ksu_sulog_emit_pending(pending_sucompat, ret, GFP_KERNEL);
    pending_sucompat = NULL;
    if (ret)
        goto out;

    /*
     * Renaming filename to /data/adb/ksud alone still runs a path-based
     * do_open_execat() with the caller's creds, which SELinux denies for
     * untrusted_app/app_data_file. Open ksud here with ksu creds and hand
     * the kernel an fd + AT_EMPTY_PATH instead (same as the syscall-hook
     * sucompat implementation).
     */
    {
        struct file *ksud_file;
        const struct cred *old_cred;
        int tmp_fd = get_unused_fd_flags(O_CLOEXEC);

        if (tmp_fd < 0) {
            pr_warn("sucompat: alloc fd failed: %d\\n", tmp_fd);
            goto out;
        }

        old_cred = override_creds(ksu_cred);
        ksud_file = filp_open(KSUD_PATH, O_PATH, 0);
        revert_creds(old_cred);
        if (IS_ERR(ksud_file)) {
            pr_warn("sucompat: open ksud failed: %ld\\n", PTR_ERR(ksud_file));
            put_unused_fd(tmp_fd);
            goto out;
        }

        fd_install(tmp_fd, ksud_file);
        *fd = tmp_fd;
        *flags |= AT_EMPTY_PATH;
        (*filename_ptr)->name[0] = '\\0';
    }

    return 0;
"""
assert s.count(old_body) == 1, 'body anchor not found'
s = s.replace(old_body, new_body)

open(path, 'w', encoding='utf-8').write(s)
print('patched FinaSU inline sucompat: %s' % path)