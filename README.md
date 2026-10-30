# venus-kernel-finaisu

> 小米 11（venus / SM8350）5.4 内核的云端 CI 编译方案：内置 [FinaSU](https://github.com/LyraVoid/FinaSU)，可选 SUSFS 回填。

个人自用折腾项目，把「改内核 → 编译 → 打 AnyKernel3 包 → 发 Release」整条链挂在 GitHub Actions 上，省掉本地 30GB 工具链和两小时编译。
**一切改动都来自公开上游，AI 参与了搭建与排错。**

---

## 目标设备

| 项 | 值 |
|---|---|
| 机型 | Xiaomi 11（venus / M2011K2C） |
| SoC | Snapdragon 888 / SM8350 |
| 内核基线 | Linux 5.4.302（`cvbyisme/android_kernel_xiaomi_sm8350_miyume`） |
| Android | 16 / HyperOS 3.0（WPBCNXM） |
| 工具链 | ZyCromerZ Clang 14.0.6 |

---

## 可用 Workflow

| 文件 | 作用 | 耗时 | 产物 |
|---|---|---|---|
| `fix.yml` | **推荐**：FinaSU 启用 + SUSFS 全关 | ~28 min | `venus-KSUnoSUSFS-*.zip` |
| `build.yml` | FinaSU + SUSFS 5.4 回填（**已知会在 venus 上崩溃**） | ~28 min | `venus-FinaSU-*.zip` |
| `pure.yml` | 不带任何 root 的纯净内核 | ~28 min | `venus-PURE-*.zip` |
| `pack.yml` | 不重编，把已有 artifact 快速打成 AK3 包 | <20 s | 复用上述产物 |
| `pack-pure.yml` | 同上，专用于 pure 产物 | <30 s | 复用上述产物 |

### 快速开始

1. Fork 本仓库
2. **Settings → Actions → General → Workflow permissions** 选 **Read and write**
3. **Actions** 页里左侧选 workflow → **Run workflow**
4. 跑完到 **Releases** 下载 zip
5. 进 TWRP 或内核刷写 App，刷 zip

---

## 为什么放弃 SUSFS

这条结论是**实测**出来的，不是猜的：

| 实验 | 结果 |
|---|---|
| FinaSU + SUSFS 5.4 回填 | 刷入后黑屏重启，卡在 init |
| 纯净内核（无 FinaSU / 无 SUSFS） | ✅ 正常开机，`5.4.302-HoshinoNeko-g88931a74` |
| FinaSU 启用 + SUSFS 全关 | 见 `fix.yml`，当前方案 |

**纯净内核能开机**这一点同时推翻了两条早期猜测：

- ~~5.4.302 与原厂 5.4.274 版本不匹配导致 vendor `.ko` vermagic 校验失败~~ → 302 内核可以正常加载原厂模块
- ~~源码树本身有问题~~ → 源码树是好的

**真正元凶**：SUSFS 5.4 回填会改动 `task_struct` 等核心结构，造成 ABI 偏移错位，init 阶段直接崩。

代替思路是 **LKM（`.ko` 模块加载）**。这版内核已确认：

```
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
```

即：FinaSU 自带的模块加载器可用，将来想上 [KPatch-Next](https://github.com/KernelSU-Next/KPatch-Next) 式 KPM 也没有配置层面的阻碍。

---

## 踩过的坑

写在这当备忘，别人少走弯路。

| 坑 | 现象 | 解决 |
|---|---|---|
| **`drivers/Kconfig` 硬引用** | 删掉 FinaSU clone 后 `make venus_defconfig` 报 `can't open file "drivers/kernelsu/Kconfig"` | 必须保留 clone 步骤来补目录，靠 `--disable KSU` 关功能而不是删目录 |
| **缺 `permissions` 导致 403** | Release 发布报 `Resource not accessible by integration` | `softprops/action-gh-release` 需要 job 级 `contents: write`，读别人 run 的 artifact 还要 `actions: read` |
| **bash 续行符** | YAML 里写 `git clone ... \` 容易变成 `\\`，shell 解析错 | 直接写单行，别用续行符 |
| **GitHub API 抖动** | PUT 文件偶发 `HTTP 500` | sleep 后重试即可，别急着改方案 |
| **SUSFS 残留** | 关掉 `CONFIG_KSU_SUSFS` 后仍可能有子开关为 `y` | `fix.yml` 里有硬门禁：`olddefconfig` 后扫 `out/.config`，发现任何 `CONFIG_*SUSFS*=y` 就 `exit 1` |

---

## 内核配置要点

`fix.yml` 实际开启/关闭的项：

```ini
# 开启
CONFIG_KSU=y
CONFIG_KPROBES=y
CONFIG_KSU_DYNAMIC_MANAGER=y

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

另外编译时注入管理器签名白名单，让 FinaSU v1.2.1 管理器能拿到 root 身份：

```makefile
KSU_EXPECTED_SIZE2=716
KSU_EXPECTED_HASH2=2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458
```

---

## 刷机风险提示

**自己承担。** 内核改动可能导致无法开机、数据丢失、变砖。

刷之前务必：

1. 备份 `boot_a` / `boot_b` 分区
2. 确认机型是 venus，别刷到别的 888 机型
3. 手边有 TWRP 或 fastboot，能救回来

已知遗留问题（`fix.yml` 未解决）：

- `KSU_REQUIRE_PREINIT` 未传
- `selinux_hide` 在 5.4 上被换成了空实现
- `ksu_handle_devpts` 补的是 `return 0` 空实现
- NoMount 在非 GKI 5.4 上大概率不可用

---

## 目录结构

```
.github/workflows/
  build.yml        FinaSU + SUSFS 完整版
  fix.yml          FinaSU 启用 / SUSFS 全关（推荐）
  pure.yml         纯净内核
  pack.yml         快速重打包
  pack-pure.yml    快速重打包（pure）
scripts/
  susfs-setup.sh   SUSFS 5.4 回填脚本（34KB）
```

---

## 致谢

- [FinaSU](https://github.com/LyraVoid/FinaSU) — root 方案本体
- [KernelSU](https://github.com/tiann/KernelSU) — 上游
- [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) — 文件系统隐藏（本项目已放弃）
- [AnyKernel3](https://github.com/osm0sis/AnyKernel3) — 刷机包模板
- [ZyCromerZ/Clang](https://github.com/ZyCromerZ/Clang) — 工具链
- 内核源码：[android_kernel_xiaomi_sm8350_miyume](https://github.com/cvbyisme/android_kernel_xiaomi_sm8350_miyume)

---

## License

脚本与 CI 配置：MIT。内核源码遵循上游 GPL-2.0。
