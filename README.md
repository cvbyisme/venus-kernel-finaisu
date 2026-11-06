# venus-kernel-finaisu

> 小米 11（venus / SM8350）5.4 非 GKI 内核，GitHub Actions 云端编译，内置 [FinaSU](https://github.com/LyraVoid/FinaSU)。
>
>
> 一切改动都来自公开上游，AI 参与了搭建、排错与文档撰写。

---

## 目标设备

| 项 | 值 |
|---|---|
| 机型 | Xiaomi 11（venus / M2011K2C） |
| SoC | Snapdragon 888 / SM8350 |
| 内核基线 | Linux 5.4.302（`cvbyisme/android_kernel_xiaomi_sm8350_miyume`） |
| Android | 16 / HyperOS 3.0（WPBCNXM） |
| 工具链 | ZyCromerZ Clang 14.0.6 |
| 内核类型 | **非 GKI**，vendor 树 |

---

## 快速开始

1. 到 **[Releases](../../releases)** 下载最新的 `venus-FinaSU-*.zip`
2. 进 **TWRP** 刷入（别在 App 里刷，原因见文末「注意」）
3. 重启，打开 FinaSU —— 首屏显示 **「工作中」** 即完成

> 无需再单独下载管理器装 ksud：内核包里已自带，刷完 `/data/adb/ksud` 就位。（准备废弃）

---

## 两条核心手段

### 一、头文件法： `-include` 来 5.4 兼容

**问题**：FinaSU 基线是 5.10+，vendor 5.4 树缺三个头文件、缺 `*_from_user_nofault` 系列、`TWA_*` 枚举也不存在。

**做法**：`scripts/preflight.sh` 生成兼容头 + `scripts/ksu54-compat.h` 补齐定义：

| 缺失项 | 来自版本 | 处理方式 |
|---|---|---|
| `<linux/pgtable.h>` | 5.8 拆出 | 生成壳 → `<asm/pgtable.h>`，补 `__p4d_to_phys` |
| `<linux/minmax.h>` | 5.10 拆出 | 生成壳 → `<linux/kernel.h>`，补 `min_t` / `max_t` |
| `<linux/hex.h>` | 6.2 拆出 | 生成壳 → `<linux/kernel.h>` |
| `{strncpy,copy_from,copy_to}_user_nofault` | 5.8 | `pagefault_disable` + 原子拷贝，手写实现 |
| `untagged_addr()` | 5.7 | 恒等宏（arm64 5.4 不做 tag 扩展） |
| `TWA_RESUME` / `TWA_NONE` / `TWA_SIGNAL` | 5.8 | `#define` 成 `true` / `false` |

**关键一步**：不逐个文件 `sed` 改 include，而是往 FinaSU 的 `KernelSU/Kbuild` 末尾追加一行 ——

```make
ccflags-y += -include $(srctree)/include/linux/ksu54_compat.h
```

所有翻译单元一次性命中，**内核源文件一行都不用改**，也不插入任何 `ksu_handle_*` 调用点。

`preflight.sh` 另外处理三件事：

- **devpts / vfs_fstat 等桩函数**从 `feature/sucompat.c` 挪到 `extension/` 独立对象，避免与 SUSFS 关闭时的链接缺符号互斥
- **preinit 关闭不能只靠 `-DKSU_NO_PREINIT`**（调用方自己 extern 声明会继续产生外部引用）→ 改从 Kbuild 摘掉 `preinit/*.o` 并注册真实空实现 `.c`
- **SUSFS 关闭时**补一份签名与 vendor 树 extern 完全匹配的 `ksu_handle_*` stub（`sys_reboot` 必须返回 `-EINVAL` 让真 reboot 流程继续）

### 二、ksud 法：AK3 里预置 ksud

**为什么必须做**：Android 16 的 app seccomp 拦掉了 `syscall(SYS_reboot, ...)` 这条路，ksud 只能先扫 `/proc/self/fd` 拿内核注入的 fd；而内核 sucompat 注入 fd 时重定向的目标固定是 `/data/adb/ksud`。**文件缺失 = 两条路全断**，FinaSU 只会显示「获取 Root 失败」。

**实现**（`scripts/ak3-ksud.sh`，CI 打包时 append 到 `anykernel.sh` 末尾）：

- 从 FinaSU APK 里抽出 `lib/arm64-v8a/libksud.so` 当 `ksud` 放进 AK3 根目录
- 判定 `/data` 是否挂载，再做一次**真实写测试**（`/data/adb` 属 DE 区，不需要 FBE 解密）
- 成功 → `/data/adb/ksud`（755 root:root）+ `/data/adb/ksu/bin/ksud` 软链
- 失败 → 落到 `/sdcard/Download/ksud`，并生成 `ksud-install.sh`，开机后 `su -c sh ...` 一次即可

**已验证**（2026-11-02，TWRP 实机）：

```
- /data/adb/ksud installed
- reboot, then open FinaSU (root ready)
```

落地校验：`/data/adb/ksud` 7717840 B，md5 `2c5fc89e…`，SELinux 上下文 `u:object_r:ksu_file:s0`（由 ksud 运行时自动重设）。

### 几个关键认知

| 认知 | 说明 |
|---|---|
| `/data/adb` 在 TWRP **可写** | 它是 DE 区，只要 `/data` 挂载成功就写得了；拿 `/data/system`（CE 区）判断会误判成「加密未解」 |
| TWRP 的 busybox 很精简 | 常见缺 `chcon`、不支持 `ls -Z`；脚本已做守卫，上下文由 ksud 运行时自设 |
| App 内刷写**不执行** `update-binary` | FinaSU / KernelFlasher 直接用 magiskboot patch boot 分区，AK3 脚本只在 TWRP 下生效 |
| 刷 boot 不会清 `/data/adb` | 所以 ksud 只需装一次，之后换内核包也不会丢 |
（准备废弃）
---

## 构建

### Workflows

| 文件 | 作用 |
|---|---|
| `build-susfs.yml` | **主构建**：FinaSU + SUSFS + 内置 ksud（准备废弃） |
| `pure.yml` | 不带 root 的纯净内核 |
| `pack.yml` / `pack-pure.yml` | 不重编，快速重打包已有产物 |
| `fix.yml` / `fix-v121.yml` | 历史分支（preinit 二分定位用，保留作参考） |

### Scripts

| 文件 | 作用 |
|---|---|
| `scripts/preflight.sh` | 5.4 兼容层施工（头文件壳、`-include` 注入、桩函数、前置校验） |
| `scripts/ksu54-compat.h` | 兼容头本体（被 `-include` 全局注入） |
| `scripts/susfs-setup.sh` | SUSFS 5.4 移植 |
| `scripts/susfs-version.sh` | SUSFS 版本对齐（v2.1.0 内核如实汇报 v2.3.0 协议，修 ctime 笔误） |
| `scripts/ak3-ksud.sh` | AK3 内置 ksud 安装器 |
| `scripts/ksu54-compat.sh`、`scripts/ksu54-v121.sh` | 早期逐文件补丁版，保留备用 |

> CI 里 `actions/checkout` 用 `path: ci`，所以脚本的真实路径是 `ci/scripts/*`（= 仓库 `scripts/*`）。

### SUSFS 版本对齐（v2.3.0 协议）

FinaSU v1.4.2 的 ksud 要求内核 SUSFS 版本字符串**精确等于 `v2.3.0`**，否则
判定 `unknown_protocol`，管理器 SUSFS 页只读、全功能不可用。本树自带 SUSFS
v2.1.0，但两者的用户态协议完全兼容（23 个 `CMD_SUSFS_*` 编号逐一相同、
`st_susfs_*` wire 结构布局一致，差异只在内核内部实现）。因此
`scripts/susfs-version.sh` 让内核如实汇报 `v2.3.0`，并顺手修掉 v2.1.0 的
`KSTAT_SPOOF_CTIME_TV_SEC (1 < 8)` 笔误（应为 `(1 << 8)`）。

钩子后端采用 **Tracepoint**：FinaSU 的 `SUSFS Inline` 后端在 5.4 上会导致
内核 panic（init exec 路径，连 recovery 也无法进入），已实机复现，故不采用。

### 功耗调优（开发中）

> 状态：**开发中，未启用**。run 14 加入下列开关后卡第一屏（recovery 可进，
> 非 panic 型崩溃），排查中；当前发布版本默认仍为 `performance` governor。

计划中的零性能代价省电开关：

| 开关 | 改动 | 理由 |
|---|---|---|
| `CPU_FREQ_DEFAULT_GOV_SCHEDUTIL` | 默认 governor `performance` → `schedutil` | SM8350 是 EAS（WALT）平台，schedutil 按负载调频：轻负载降频省电，突发负载性能不变 |
| `WQ_POWER_EFFICIENT_DEFAULT` | 开启 | 内核工作队列优先调度到低功耗核 |
| `SCHED_DEBUG` / `PROFILING` | 关闭 | 移除调度器调试记账与 profiling 钩子开销 |

相关改动保留在 fork 的 `power-wip` 分支，调试完成后重新提交。

---

## Releases

从 Releases 直接下包，不用去 Actions 页面 artifact：

| Tag | 内容 |
|---|---|
| **[`ak3-ksud-v3`](https://github.com/cvbyisme/venus-kernel-finaisu/releases/tag/ak3-ksud-v3)** | FinaSU + AK3 内置 ksud（准备废弃），刷完即用（2026-11-02 实机验证） |
| `susfs-test-1` / `susfs-test-2` | 早期 FinaSU + SUSFS 试验包 |
| `pure-ak3-1` | 纯净内核（无 root），用于排查 |
| `ak3-1` / `ksuns-5` | 更早的构建产物 |

---

## 注意（很重要）

- 从 **FinaSU 管理器 / KernelFlasher** 这类 App 内刷写时，刷写器用 `magiskboot` 直接 patch boot 分区，**不执行 `update-binary`** —— 所以 AK3 脚本只在 **TWRP** 下生效。
- 刷 boot 分区不会清掉 `/data/adb/ksud`，因此只需在 TWRP 里成功装过一次。（准备废弃）

---

## 踩坑速查

| 现象 | 原因 |
|---|---|
| 卡第一屏 / 黑屏重启 | 内核树 hook 调用点来自 v1.2.1 时代，却拼了 master 的实现（签名、符号名全对不上） |
| `fatal error: 'linux/pgtable.h' file not found` | 5.8 才拆出的头文件，5.4 没有 → 交给头文件法兜底 |
| `undefined symbol: ksu_handle_devpts` 等 | vendor 树仍带旧 hook，FinaSU 已不实现 → 补签名精确匹配的 stub |
| `-DKSU_NO_PREINIT` 不生效 | 调用方自己 extern 声明，仍产生外部引用 → 摘掉对象 + 真实空实现 |
| FinaSU 报「获取 Root 失败」 | `/data/adb/ksud` 缺失 + Android 16 seccomp 拦 reboot syscall → AK3 内置 ksud |
| AK3 里 `chcon: not found` / `ls: invalid option -- Z` | osm0sis busybox 精简 → 已加守卫，不影响功能 |

---

## 刷机风险提示

- 涉及 boot 分区，**刷前务必备份原厂 boot**
- 首次刷建议备好原厂 `boot.img` 或可进入的 TWRP，方便回滚
- 内核与 ROM 版本强相关，跨大版本 ROM 升级后可能需要重刷

---

## 目录结构

```
.github/workflows/     CI 定义
scripts/               构建与 AK3 脚本
README.md              本文档
```

---

## 贡献者

| 贡献者 | 贡献 |
|---|---|
| **@cvbyisme** | 项目发起、内核 fork 维护、构建与实机验证 |
| **@LuNanzhi**（仓库共创者） | 关键贡献：preflight 兼容层思路、bugreport 定位、AK3 内置 ksud 可行路线与成功设备取证 |
| AI（Operit / Claude 系模型） | 代码实现、CI 调试、文档撰写 |

---

## 参考仓库

- [LyraVoid/FinaSU](https://github.com/LyraVoid/FinaSU) —— root 方案本体
- [MiYume0721/android_kernel_xiaomi_sm8350_miyume](https://github.com/MiYume0721/android_kernel_xiaomi_sm8350_miyume) —— 内核基线
- [osm0sis/AnyKernel3](https://github.com/osm0sis/AnyKernel3) —— 刷机包模板
- [LuNanzhi/venus-kernel-finaisu](https://github.com/LuNanzhi/venus-kernel-finaisu) —— 同设备参考实现

---

## License

见 [LICENSE](LICENSE)。
