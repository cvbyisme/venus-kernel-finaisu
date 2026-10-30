# venus-kernel-finaisu

> 小米 11（venus / SM8350）5.4 非 GKI vendor 内核，云端 GitHub Actions 编译，内置 [FinaSU](https://github.com/LyraVoid/FinaSU)。

小米 11 的第三方 FinaSU 内核试验品。**一切改动都来自公开上游，AI 参与了搭建、排错与文档撰写。**

---

## 目标设备

| 项 | 值 |
|---|---|
| 机型 | Xiaomi 11（venus / M2011K2C） |
| SoC | Snapdragon 888 / SM8350 |
| 内核基线 | Linux 5.4.302（`cvbyisme/android_kernel_xiaomi_sm8350_miyume`） |
| Android | 16 / HyperOS 3.0（WPBCNXM） |
| 工具链 | ZyCromerZ Clang 14.0.6 |
| 内核类型 | **非 GKI**，vendor 树，无 `CONFIG_HEADERS_INSTALL` |

---

## 可用 Workflow

| 文件 | 作用 | 耗时 | 产物 | 状态 |
|---|---|---|---|---|
| `fix.yml` | FinaSU **master** + SUSFS 全关 + 强制关 preinit | ~28 min | `venus-KSUnoSUSFS-*.zip` | ❌ 卡第一屏 |
| `fix-v121.yml` | FinaSU **v1.2.1** + SUSFS 全关 + 强制关 preinit | ~28 min | `venus-KSUv121-*.zip` | 🧪 实验中 |
| `build.yml` | FinaSU + SUSFS 5.4 回填 | ~28 min | `venus-FinaSU-*.zip` | ❌ 已知崩溃 |
| `pure.yml` | 不带 root 的纯净内核 | ~28 min | `venus-PURE-*.zip` | ✅ 能开机 |
| `pack.yml` | 不重编，快速重打包 | <20 s | 复用上述产物 | — |
| `pack-pure.yml` | 同上，专用于 pure | <30 s | 复用上述产物 | — |

### 快速开始

1. Fork 本仓库
2. **Settings → Actions → General → Workflow permissions** 选 **Read and write**
3. **Actions** 页左侧选 workflow → **Run workflow**
4. 跑完到 **Releases** 下载 zip
5. 进 TWRP 或内核刷写 App，刷 zip

---

## 完整排查历程

这一节记录了从零到定位根因的**全部实验与结论**，包括走过的弯路。

### 阶段 0：基线确认

| 实验 | 配置 | 结果 |
|---|---|---|
| 纯净内核 | `CONFIG_KSU=n`，无任何补丁 | ✅ **正常开机**，`5.4.302-HoshinoNeko-g88931a74` |
| FinaSU + SUSFS 回填 | `CONFIG_KSU=y` + `build.yml` | ❌ 黑屏重启，卡在 init |
| FinaSU + SUSFS 全关 | `CONFIG_KSU=y` + `fix.yml` | ❌ 卡第一屏 |

**关键推论**：同一个内核源码仓库，仅仅 `CONFIG_KSU` 从 `n` 变 `y` 就崩，说明**源码树本身是好的**，问题在 KernelSU 的集成方式上。

### 阶段 1：被证伪的两个错误猜测

| 猜测 | 证伪证据 |
|---|---|
| ~~5.4.302 与原厂 5.4.274 vermagic 不匹配~~ | 302 内核能正常加载原厂 vendor 模块 |
| ~~SUSFS 5.4 回填改动 `task_struct` 造成 ABI 偏移~~ | **无 SUSFS 的 `ksuns-5` 同样卡屏**——这条彻底推翻 |

> 这条曾经的「真正元凶」结论是错的。没有 SUSFS 也一样崩，说明 SUSFS 只是加重因素，不是根本原因。

### 阶段 2：读原版 KernelSU，确认它不支持 5.4

拉取 `tiann/KernelSU` 的 `kernel/Kbuild` 与 `kernel/core/init.c`：

| 发现 | 说明 |
|---|---|
| 官方最低 **5.10 GKI** | 靠 `ksu_syscall_hook_init()` + kprobe + kallsyms 运行时解析 |
| `ksu_preinit_init()` 只在 `ksu_late_loaded == false` 时调用 | 即仅内置模式 |
| preinit 依赖 `$(objtree)/usr/include/linux/unistd.h` | Kbuild 注释明写由 `CONFIG_HEADERS_INSTALL`（gki_defconfig）提供，**vendor 5.4 通常没有** |
| LKM 是官方给第三方内核留的路 | `ksu_late_loaded = (current->pid != 1)` → `pr_info("late load mode, skipping kprobe hooks")` → `apply_kernelsu_rules()` / `cache_sid()` / `setup_ksu_cred()` / `escape_to_root_for_init()`，**完全不碰 init 的 execve** |

**推论**：preinit 在 venus 上很可能**一直处于静默禁用状态**，所以专门关它的 D1 补丁可能等于没改。

### 阶段 3：回到内核源码，找到真相

#### 3.1 内核树自带 KernelSU 集成

| 位置 | 内容 |
|---|---|
| `drivers/Kconfig` 末行 | `source "drivers/kernelsu/Kconfig"` |
| `drivers/kernelsu` | **符号链接**（18 字节）→ `../KernelSU/kernel` |
| `KernelSU/` | **git submodule** → `https://github.com/LyraVoid/FinaSU.git` |
| submodule 锁定 commit | `a9216b04e29cc973ddbf845342f2cbf85b47b460` |

#### 3.2 内核树早就被旧版 KSU 补丁污染过

`fs/open.c` 里的硬证据：

```c
346: #ifdef CONFIG_KSU
347: extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user,
348:                                 int *mode, int *flags);
...
441: #ifdef CONFIG_KSU
442:     ksu_handle_faccessat(&dfd, &filename, &mode, &flags);
443: #endif

```

另有：

```c
35:   #ifdef CONFIG_KSU_SUSFS
...
1217: #if defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)
1259: #endif // #ifdef CONFIG_KSU_SUSFS_OPEN_REDIRECT

```

> **`CONFIG_KSU=n` 时这些全被预处理器剔除**，所以纯净内核当然能开机。一开 `=y`，这些调用点就开始找符号。

#### 3.3 fork 与上游的差异

| 项 | 值 |
|---|---|
| 上游 | `MiYume0721/android_kernel_xiaomi_sm8350_miyume` |
| your fork | `cvbyisme/android_kernel_xiaomi_sm8350_miyume` |
| 差异 | **ahead 30 / behind 0** |
| 30 个 commit 动过的文件 | `.github/scripts/susfs-setup.sh`、`.github/workflows/build-venus-finaus.yml`、`.gitmodules`、`arch/arm64/configs/venus_defconfig` |
| `fs/` `kernel/` `mm/` | **一行也没动** |

**结论**：调用点不是我们加的，是**上游内核树本来就有的**。

#### 3.4 FinaSU 的 `setup.sh` 到底干嘛

`kernel/setup.sh`（v1.2.1，4020 字节）只做三件事：

```sh
ln -sf "$(realpath --relative-to="$DRIVER_DIR" "$SRC_DIR/kernel")" "kernelsu"
printf "\nobj-$(CONFIG_KSU) += kernelsu/\n" >> drivers/Makefile
sed -i "/endmenu/i source \"drivers/kernelsu/Kconfig\"" drivers/Kconfig

```

`--cleanup` 就是反向删这三样。

> **它完全不碰任何内核源文件**，也不插入任何 `ksu_handle_*` 调用点。

### 阶段 4：根因定论 —— **KernelSU 版本错配**

#### 4.1 submodule 锁定的 commit 已被上游删除

```
commits/{a9216b0}      → HTTP 422
 git/commits/{a9216b0} → HTTP 404
 master / dev / susfs2_GKI / feat-nomount-builtin / feat-lkm-manager → 全部 422

```

> 这个 commit 已被 FinaSU 上游 **force-push 删除**，仓库里彻底找不到。

#### 4.2 时间线对上了 v1.2.1

| 事件 | 时间（UTC） |
|---|---|
| `v1.2.1` tag 创建 | **2026-10-25 14:29:54** |
| 你的 fork 最后一次 push | **2026-10-25 14:56:18** |
| 间隔 | **27 分钟** |

`v1.2.1` → commit `be19eb90b9c7b96f265c86b733aa0640a2839bdb`

README 里的管理器签名 `KSU_EXPECTED_HASH2` 对应的也是 v1.2.1。

#### 4.3 我们实际用的是什么

`fix.yml` 里写的是：

```yaml
git clone --depth 1 --branch "${{ inputs.ksu_ref || 'master' }}" \
  https://github.com/LyraVoid/FinaSU.git kernel/KernelSU

```

默认取 **master 头**，比内核树期望的 v1.2.1 跨了 **v1.3.0 / v1.3.1 / v1.3.2** 三个版本。

### 根因一句话

> **内核树的 hook 调用点来自 v1.2.1 时代，我们却把它和 master 的实现拼在一起。签名、符号名、调用顺序全对不上，init 阶段找不到符号或陷入异常，卡在第一屏。**

不是 SUSFS，不是 preinit，不是 ABI，也不是源码树坏了。

### v1.2.1 与 master 的具体差异

| 项 | v1.2.1 | master |
|---|---|---|
| `ksu_handle_faccessat` 签名 | `struct filename **` | `const char __user **` |
| `KSU` 的 Kconfig 依赖 | `KPROBES && EXT4_FS` | `KPROBES` |
| 额外 feature 对象 | `avc_spoof.o`、`mount_view_filter.o` | 已移除/合并 |
| `KSU_DYNAMIC_MANAGER` 判法 | `ifneq ($(...),n)`（默认开） | `ifeq ($(...),y)` |
| `uapi/` 位置 | 仓库根 `uapi/supercall.h` | 同 |
| preinit 编译条件 | 完全一致（同样受 `usr/include/linux/unistd.h` 控制） | 同 |

---

## 实验记录

### D1（已取消）—— master + 强制关 preinit

| 项 | 值 |
|---|---|
| run | `41144239963` / run_number 6 |
| 方案 | 在 `ksu54-compat.sh` 注入 step 10，强制 `-DKSU_NO_PREINIT` |
| 结果 | **主动取消**（根因已定位，不需要验证） |

补丁内容（652 行脚本，MD5 `acc14014c8fc476473dffe05420892ba`）：

```python
old_objs = 'kernelsu-objs += preinit/preinit.o\nkernelsu-objs += preinit/blob.o\n'
new_objs = '# ksu54_force_no_preinit: diagnostic build, preinit disabled\nccflags-y += -DKSU_NO_PREINIT\n'

```

> 注：Kbuild 上游的 `else` 分支**原生就有** `ccflags-y += -DKSU_NO_PREINIT`，所以幂等判断不能拿这个字符串，要用自定义标记 `ksu54_force_no_preinit`。

### B（进行中）—— v1.2.1 + 最小补丁

| 项 | 值 |
|---|---|
| workflow | `.github/workflows/fix-v121.yml`（224 行，12 步） |
| 补丁 | `scripts/ksu54-v121.sh`（884 字节，极简） |
| FinaSU ref | `v1.2.1`（完整 clone 后 checkout，不用 `--depth`） |
| 新增配置 | `--enable EXT4_FS`（v1.2.1 Kconfig 硬依赖） |
| 产物 | `venus-KSUv121-YYYYMMDD-runN.zip`，tag `ksuv121-N` |

**思路：把变量减到最少** —— 先只求能开机，再逐项加功能。

编译失败后按报错逐个补（预期可能缺：`minmax.h`、`hex.h`、`seccomp.filter_count` 等 5.4 不存在的符号）。

### 后续预案

| 方案 | 内容 | 触发条件 |
|---|---|---|
| C | 彻底剥掉内核树老 KSU/SUSFS 补丁后配最新 FinaSU | B 也不通 |
| D | 走 LKM 路线（`CONFIG_MODULES=y` 已确认可用） | 内置模式长期受阻 |
| E | 抓 dmesg / pstore 看具体 panic | 需要更多诊断信息 |

---

## 已知遗留问题

即使能开机，以下仍未解决：

| 问题 | 影响 |
|---|---|
| `KSU_REQUIRE_PREINIT` 未传 | preinit 相关逻辑不完整 |
| `selinux_hide` 在 5.4 上是空实现 | SELinux 可见性可被检测 |
| `ksu_handle_devpts` 补的是 `return 0` | devpts 相关隐藏失效 |
| NoMount 在非 GKI 5.4 上大概率不可用 | 挂载隐藏能力缺失 |
| 10 项 SUSFS 全关 | root 隐藏能力基本为零 |

> **这些包只能用于调试，不建议作为日常使用内核。**

---

## 内核配置要点

```ini

# 开启
CONFIG_EXT4_FS=y              # v1.2.1 的 KSU 硬依赖
CONFIG_KPROBES=y
CONFIG_KSU=y
CONFIG_KSU_DYNAMIC_MANAGER=y
CONFIG_MODULES=y              # 给 LKM 路线留口子
CONFIG_KALLSYMS_ALL=y

# 强制关闭（10 项）
CONFIG_KSU_SUSFS=n
CONFIG_KSU_SUSFS_SUS_PATH=n
CONFIG_KSU_SUSFS_SUS_MOUNT=n
CONFIG_KSU_SUSFS_SUS_KSTAT=n
CONFIG_KSU_SUSFS_SPOOF_UNAME=n
CONFIG_KSU_SUSFS_ENABLE_LOG=n
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=n
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=n
CONFIG_KSU_SUSFS_OPEN_REDIRECT=n
CONFIG_KSU_SUSFS_SUS_MAP=n

```

管理器签名白名单（编译时注入）：

```makefile
KSU_EXPECTED_SIZE2=716
KSU_EXPECTED_HASH2=2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458

```

> 对应 **FinaSU v1.2.1 管理器**，装错版本管理器拿不到 root。

---

## 踩过的坑

| 坑 | 现象 | 解决 |
|---|---|---|
| **`drivers/Kconfig` 硬引用** | 删掉 FinaSU clone 后 `make venus_defconfig` 报 `can't open file "drivers/kernelsu/Kconfig"` | 必须保留 clone 步骤补目录，靠 `--disable KSU` 关功能而不是删目录 |
| **缺 `permissions` 导致 403** | Release 报 `Resource not accessible by integration` | job 级要 `contents: write`，读别人 artifact 还要 `actions: read` |
| **bash 续行符** | YAML 里 `git clone ... \` 容易变 `\\` | 直接写单行 |
| **GitHub API 抖动** | PUT 偶发 `HTTP 500` | sleep 重试，别急着换方案 |
| **SUSFS 残留** | 关掉父项后子项仍可能 `=y` | `olddefconfig` 后扫 `out/.config`，发现任何 `CONFIG_*SUSFS*=y` 就 `exit 1` |
| **幂等判断撞原生内容** | 用 `grep -q 'KSU_NO_PREINIT'` 当标记，误判成已打补丁 | Kbuild 上游 `else` 分支原生就有这行，必须用自定义标记 |
| **`SUDIR=x bash s.sh` 写在 `&&` 后面** | 环境变量丢失，脚本拿到空值 | 必须作为命令前缀单独写 |
| **`create_or_update_file` 的 `content`** | 传占位符真的会覆盖远端文件 | 宁可 `base64` + `curl -X PUT`，不用占位符 |
| **`--depth 1` + 任意 ref** | 想 checkout `v1.2.1` 会失败，浅克隆拿不到 tag | 完整 clone 后再 checkout |

---

## 刷机风险提示

**自己承担。** 内核改动可能导致无法开机、数据丢失、变砖。

刷之前务必：

1. 备份 `boot_a` / `boot_b` 分区
2. 确认机型是 **venus**，别刷到别的 888 机型
3. 手边有 TWRP 或 fastboot，能救回来

卡屏时怎么醒：

```sh
fastboot reboot          # 多数情况能直接重启
fastboot flash boot boot.img   # 刷回备份的原厂/纯净 boot

```

---

## 目录结构

```
.github/workflows/
  build.yml        FinaSU + SUSFS 完整版
  fix.yml          FinaSU master / SUSFS 全关
  fix-v121.yml     FinaSU v1.2.1 / SUSFS 全关（当前实验）
  pure.yml         纯净内核
  pack.yml         快速重打包
  pack-pure.yml    快速重打包（pure）
scripts/
  susfs-setup.sh   SUSFS 5.4 回填脚本（34 KB）
  ksu54-compat.sh  master 用的 5.4 兼容补丁（652 行）
  ksu54-v121.sh    v1.2.1 用的极简补丁（884 字节）

```

---

## 参考仓库

| 仓库 | 用途 |
|---|---|
| [tiann/KernelSU](https://github.com/tiann/KernelSU) | 上游本体，最低 5.10 GKI |
| [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) | 本项目使用的 root 方案 |
| [MiYume0721/android_kernel_xiaomi_sm8350_miyume](https://github.com/MiYume0721/android_kernel_xiaomi_sm8350_miyume) | 内核源码上游（**已内置 KSU 集成**） |
| [cvbyisme/android_kernel_xiaomi_sm8350_miyume](https://github.com/cvbyisme/android_kernel_xiaomi_sm8350_miyume) | 本项目的内核 fork |
| [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) | 刷机包模板 |
| [ZyCromerZ/Clang](https://github.com/ZyCromerZ/Clang) | 工具链 |
| [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu) | SUSFS（本项目已放弃） |

---

## 给后来者的话

如果你也在给 **非 GKI 的 5.4 vendor 树** 上 KernelSU，先做这件事：

```sh

# 1. 查内核树里有没有残留的 KSU hook
grep -rn 'CONFIG_KSU' fs/ kernel/ mm/ drivers/ --include=*.c --include=*.h | head -50

# 2. 看 submodule 锁的是哪个 commit
git ls-tree HEAD KernelSU

# 3. 对比那个 commit 和你要用的 tag 是不是同一个
git -C KernelSU log --oneline -1 <那个sha>

```

**第 3 步是关键。** 我们在前两步都对、第三步错的情况下，白白花了好几轮编译（共 6 次，近 3 小时）才定位到版本错配。

> 一句话教训：**内核树里的 hook 调用点和 KernelSU 实现是一对锁和钥匙，必须版本配套。**

---

## License

脚本与 CI 配置：MIT。内核源码遵循上游 GPL-2.0。
