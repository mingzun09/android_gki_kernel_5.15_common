# Android GKI 通用内核镜像 — android13-5.15

基于 Linux **5.15.209** 的 **android13-5.15 GKI** 通用内核源码（已测试于 Xiaomi 13）。

仓库内置 **GitHub Actions 工作流**：不需要本地环境，点一次就能构建出可直接刷入的
**KernelSU / KernelSU-Next / BakaSU + SUSFS** 内核包（AnyKernel3 格式）。

- 内核版本：Linux 5.15.209 `Trick or Treat`
- Android 版本：Android 13 (API 33)，KMI Generation 8
- 目标架构：AArch64 (ARM64)
- 仓库自带构建系统工具链：Clang **r547379**（见 `build.config.constants`）
- Actions 工作流工具链：AOSP Clang **r450784e**（14.0.7，android13-5.15 原生版本）

## 目录

- [快速开始：用 Actions 一键构建](#快速开始用-actions-一键构建)
- [产物与安装](#产物与安装)
- [工作流与输入参数](#工作流与输入参数)
- [本地构建](#本地构建)
- [缓存与资源治理](#缓存与资源治理)
- [实测数据](#实测数据)
- [已知限制](#已知限制)
- [内核特性](#内核特性)
- [ABI 兼容性](#abi-兼容性)
- [项目结构](#项目结构)
- [开发指南](#开发指南)
- [许可证](#许可证)

---

## 快速开始：用 Actions 一键构建

1. 打开仓库 → **Actions** 标签页 → 左侧选中要用的工作流
2. 右侧 **Run workflow** → 选择分支（默认 `serein`）→ 按需填写输入参数 → 运行
3. 构建完成后，在该次运行页面的 **Artifacts** 区下载 **`...-anykernel3`**（单个 zip）
4. 刷入设备，见 [产物与安装](#产物与安装)

> 三条 KernelSU/SUSFS 工作流都是**手动触发**（`workflow_dispatch`），不会自动占用额度。
> 仓库里既有的 `build_gki.yml` / `build_gki_ksu.yml` 是 Bazel 路线（产物为整棵 `out/` 树；
> `build_gki_ksu.yml` 每天 00:00 UTC 定时跑），与下面三条纯 `make` 路线互相独立。

### 该选哪条？

| 你想要 | 用哪个工作流 | 说明 |
|---|---|---|
| 内核内 SUSFS + 官方 KernelSU（最省事，SUSFS 编进内核） | `build_gki_kernelsu_susfs.yml` | 内核侧 susfs 补丁由 susfs4ksu 提供，KernelSU 侧用配套补丁 |
| 内核内 SUSFS + BakaSU | `build_gki_bakasu_susfs.yml` | BakaSU 自带 KSU 侧胶水，只打内核侧补丁 |
| KernelSU-Next 官方路线（SUSFS 为独立 LKM 模块） | `build_gki_ksunext_susfs.yml` | 内核不打 SUSFS 补丁，改用 KernelSU-Next 自带的 `susfs_guard_lkm.ko` |

> **为什么 KernelSU-Next 不能用内核内 SUSFS 补丁**：KernelSU-Next（v3.2.0 ~ v3.4.2、dev）没有任何版本定义
> `CONFIG_KSU_SUSFS`，且内核侧补丁需要的 11 个 `ksu_*` 符号在 KernelSU-Next 中一个都没有（命中 0/11）；
> 套上去只会得到被 `#ifdef` 关掉的死代码，强行打开则是链接失败。因此内核内 SUSFS 配原版 KernelSU / BakaSU，
> KernelSU-Next 走它自带的 LKM 形态。

## 产物与安装

### 产物内容

三条 KSU/SUSFS 工作流**只上传一个文件**：`GKI-5.15-<集成>-<ref>-anykernel3`（内含 `anykernel.zip`，约 21 MB）。
为了保证"只留一个包"不丢东西，原先单独上传的内容都已打进包里：

| 包内文件 | 说明 |
|---|---|
| `Image` | 内核镜像（约 38 MB） |
| `susfs_guard_lkm.ko` | 仅 KernelSU-Next 线：SUSFS 独立模块（约 565 KB） |
| `build-info.txt` | 仓库提交、KernelSU/SUSFS 版本、内核 release、Image sha256、工具链、构建时间 |
| `kernel-config.txt` | 本次构建的完整 `.config` |
| `susfs-patch-info.txt` | 仅内核内 SUSFS 的两条线：补丁 md5 与上游 commit |
| `anykernel.sh` / `META-INF/` / `tools/` / `LICENSE` | AnyKernel3 刷机模板（来自 `anykernel_template/`） |

编译日志只在**失败时**额外上传（`build-logs-<run_id>`），成功不占产物配额。

### 刷入

1. **备份原 boot**（务必），再用 Recovery 刷入 `anykernel.zip`（AnyKernel3 模板会自动处理 boot 镜像）
2. **仅 KernelSU-Next 线**：SUSFS 是独立模块，刷完包后还需手动加载：
   ```bash
   # 从 anykernel.zip 解压出 susfs_guard_lkm.ko，然后
   adb push susfs_guard_lkm.ko /data/local/tmp/
   adb shell su -c "ksud insmod /data/local/tmp/susfs_guard_lkm.ko"
   # 或让它开机自动加载
   adb shell su -c "ksud susfs autoload enable"
   ```
   > `ksud susfs load` 只会加载 ksud 内嵌的官方 KMI 版本模块（vermagic 是官方 release 串，装不进自编译内核），
   > 自编译内核请用上面的 `ksud insmod`。
3. **内核内 SUSFS 的两条线**（官方 KernelSU / BakaSU）：SUSFS 已编进内核，刷完即生效。
   后续如需配置隐藏规则（`sus_path`、`sus_mount` 等），使用 simonpunk 侧的 `ksu_susfs` 命令行工具（本项目不构建该工具）。

### 版本串

默认形如 `5.15.209-serein-android13-8-<日期>-g<sha>-dirty`（内核树在集成后会变脏，属预期）。
如需固定，用输入 `kernel_version_suffix`（写入 `CONFIG_LOCALVERSION`，同时关闭 `LOCALVERSION_AUTO`）
与 `build_time`（写入 `KBUILD_BUILD_TIMESTAMP`）：

```
kernel_version_suffix = -mykernel-1.0   →  5.15.209-mykernel-1.0
build_time            = Sun Dec 01 08:10:00 UTC 2024
```

## 工作流与输入参数

| 工作流文件 | 显示名 | 集成内容 | 触发 | 产物 |
|---|---|---|---|---|
| `build_gki_ksunext_susfs.yml` | Build GKI 5.15 KernelSU-Next + SUSFS | KernelSU-Next + SUSFS(LKM) | 手动 | `GKI-5.15-KSUNext-*-anykernel3` |
| `build_gki_kernelsu_susfs.yml` | Build GKI 5.15 KernelSU + SUSFS (in-kernel) | 官方 KernelSU + 内核内 SUSFS | 手动 | `GKI-5.15-KernelSU-SUSFS-*-anykernel3` |
| `build_gki_bakasu_susfs.yml` | Build GKI 5.15 BakaSU + SUSFS (in-kernel) | BakaSU + 内核内 SUSFS | 手动 | `GKI-5.15-BakaSU-SUSFS-*-anykernel3` |
| `build_gki.yml` | Build GKI Kernel | 无（纯 GKI） | push `serein` / 手动 | `GKI-Kernel-5.15`（整棵 `out/`） |
| `build_gki_ksu.yml` | Build GKI with KernelSU | KernelSU（Bazel 路线） | 每天 00:00 UTC / 手动 | `GKI-Kernel-5.15-KernelSU`（整棵 `out/`） |
| `cleanup-caches.yml` | Cleanup Actions caches & artifacts | 缓存/产物/运行记录清理 | 每周日 03:17 UTC / 手动 | — |

### KernelSU-Next + SUSFS

| 输入 | 默认 | 说明 |
|---|---|---|
| `ksu_ref` | `v3.4.2` | KernelSU-Next 的 tag / 分支 / commit（留空取最新 tag；建议填 tag 保证可复现） |
| `susfs_mode` | `lkm` | SUSFS 集成方式（`lkm` = 编译 `susfs_guard_lkm.ko`；`off` = 不集成） |
| `build_modules` | `false` | 是否额外执行 `make modules` |
| `kernel_version_suffix` | 空 | 固定版本串 |
| `build_time` | 空 | 固定编译时间戳 |
| `ccache_max_size` | `2G` | ccache 容量上限 |

### 官方 KernelSU + 内核内 SUSFS

| 输入 | 默认 | 说明 |
|---|---|---|
| `ksu_ref` | `v3.3.1` | tiann/KernelSU 的 tag / commit（实测该 tag 与当前 SUSFS 补丁零冲突） |
| `susfs_ref` | `2ad2973…` | susfs4ksu 的 commit（默认是验证过的那个） |
| `build_modules` | `false` | 是否额外执行 `make modules` |
| `kernel_version_suffix` / `build_time` / `ccache_max_size` | 空 / 空 / `2G` | 同上 |

### BakaSU + 内核内 SUSFS

| 输入 | 默认 | 说明 |
|---|---|---|
| `bakasu_ref` | `v4.2.0-rc3` | BakaSU 的 tag（⚠ `main` 分支被上游主动禁用 SUSFS 构建，不能用） |
| `susfs_ref` | `2ad2973…` | 同上 |
| `build_modules` / `ccache_max_size` | `false` / `2G` | 同上 |

### 清理工作流 `cleanup-caches.yml`

手动触发默认 **`dry_run=true`**（只报告不删除）。可调：`keep_days`(14)、`artifacts_days`(30)、
`runs_days`(0)、`purge_all_caches`(false)、`max_delete`(300)、`protected_keys`(`Linux-repo-sync-v1`)、
`keep_newest_ccache`(3)。详见 [缓存与资源治理](#缓存与资源治理)。

### 工作流的硬断言

三条 KSU/SUSFS 工作流在关键环节直接失败报错，不做静默通过：

- 补丁 `.rej` 数量必须为 **0**（非 0 时打印每个 `.rej` 内容后退出）
- `out/.config` 里 `CONFIG_KSU=y` 且（内核内路线）`CONFIG_KSU_SUSFS=y`，BakaSU 线还要求
  `CONFIG_KSU_TRACEPOINT_HOOK` 不为 y
- SUSFS 补丁的 md5 指纹与验证过的一致（上游改动会立刻报错）
- BakaSU 集成后 HEAD 必须等于 pin 的 commit（`setup.sh` 的 checkout 失败会静默退回 `main`）
- 只编 `Image` 不会生成 `Module.symvers`/`module.lds`，因此需要 LKM 或模块时会先跑一遍 `make modules`

## 本地构建

### 方式一：Bazel（仓库既有构建系统）

```bash
# 在 repo 工作目录根执行（需 repo sync 环境）
tools/bazel build //common:kernel_aarch64_dist

# 或用构建配置
BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh
```

### 方式二：`build_gki.sh` 脚本

```bash
./build_gki.sh [OPTIONS]
#   --ksu       启用 KernelSU
#   --ak3       生成 AnyKernel3 包
#   --img       生成 boot.img
#   --profile   性能分析
#   --clean / --no-clean
```

脚本内含环境检查、温度监控（防过热）、版本自定义与产物打包（`Image.gz`、`boot.img`、`anykernel.zip`）。
`repack_boot.sh` 可用编译出的 Image 重新打包 `boot-new.img`。

### 方式三：纯 make + AOSP Clang（Actions 工作流采用）

```bash
# 1) 工具链（android13-5.15 原生 clang r450784e）
wget "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master-kernel-build-2022/clang-r450784e.tar.gz" -O clang.tar.gz
mkdir -p clang && tar -xzf clang.tar.gz -C clang/
export PATH="$PWD/clang/bin:$PATH"

# 2) KernelSU 集成（以 KernelSU-Next 为例）
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/v3.4.2/kernel/setup.sh" | bash -s v3.4.2

# 3) 关键修正 + 配置
sed -i 's/-mllvm -regalloc-enable-advisor=release/-mllvm -regalloc-enable-advisor=default/g' Makefile   # 见下方说明
echo 'CONFIG_KSU=y' >> arch/arm64/configs/gki_defconfig
echo 'CONFIG_WERROR=n' >> arch/arm64/configs/gki_defconfig

# 4) 编译
make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 gki_defconfig
make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
make -j"$(nproc)" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 Image Image.gz
```

**换用 clang 14 时必踩的三个坑**（工作流里已处理）：

1. **MLGO regalloc**：AOSP clang-r450784e 的 `lib64` 里没有 MLGO 模型文件，而 ACK 的 `Makefile` 硬编码了
   `-mllvm -regalloc-enable-advisor=release`，从 `-O1` 起每个文件都报
   `Requested regalloc eviction advisor analysis could be created`。修法是把它改成 `=default`（必须改 Makefile，
   命令行再追加一个会报 "may only occur zero or one times"）。
2. **外部模块**：只编 `Image` 不会生成 `Module.symvers` 与 `scripts/module.lds`，编译 SUSFS LKM 会直接失败；
   先跑 `make modules`。该 LKM 有 6 个内核未导出符号（`task_work_add`/`init_mm`/`__set_fixmap`/
   `copy_to_kernel_nofault`/`dcache_clean_inval_poc`/`saved_boot_config`），上游设计就是加载时用 kallsyms 解析，
   所以需要 `KBUILD_MODPOST_WARN=1` 放行 modpost。
3. **`set -o pipefail` + `strings Image | grep -m1`**：`grep -m1` 提前关闭管道会让 `strings` 收到 SIGPIPE，
   整个步骤被误判为失败 —— 先落盘再 grep。

## 缓存与资源治理

- Actions 的缓存配额是**每个仓库 10 GB**，超出时 GitHub 按"最后访问时间"淘汰 —— 可能正好挤掉最贵的那份缓存。
- 三条 KSU/SUSFS 工作流的 ccache 缓存 key **按天轮转**（`date -u +%Y%m%d`）：同一天重跑共享一份缓存，
  每天最多新增一条，避免"每次运行都新建条目"把配额塞满。
- `build_gki.yml` 的 AOSP 源码/prebuilts 缓存（`Linux-repo-sync-v1`，实测约 8 GB）在清理工作流里**默认受保护**，
  定时清理不会碰它。
- 手动清理：Actions → **Cleanup Actions caches & artifacts** → Run workflow（默认 dry-run，先看会删什么）。
- 本地清理（需已登录的 `gh`）：
  ```bash
  .github/scripts/cleanup_gh_cache.sh                        # 默认 dry-run
  .github/scripts/cleanup_gh_cache.sh --apply                # 删除 14 天未访问的缓存
  .github/scripts/cleanup_gh_cache.sh --apply --no-protect --keep-days 0   # 连受保护的大缓存也清
  ```
- ccache 在本地的配置与统计说明见 [`CCACHE_SETUP.md`](CCACHE_SETUP.md)。

## 实测数据

以下为本机 16 核环境（AOSP clang r450784e，纯 `make`）的实测值，供参考；GitHub runner（`ubuntu-latest`，4 vCPU）
首次冷构建会明显更慢：

| 项目 | 数值 |
|---|---|
| 冷构建 | KernelSU-Next 线约 7 分钟；BakaSU 线 446 秒 |
| ccache 命中后重建 | 2 分 49 秒（命中 99.86%，2928 次可缓存调用命中 2924 次） |
| `Image` | 38.3 MB |
| `Image.gz` | 18.3 MB |
| `susfs_guard_lkm.ko` | 565,648 字节（`llvm-strip -d` 后；vermagic 与内核 release 一致） |
| `anykernel.zip` | 约 21 MB |

## 已知限制

- 三条 KSU/SUSFS 工作流的 `run` 步骤已在本机把 YAML 逐条抽出 1:1 重放通过（含完整编译与打包），
  但**尚未在 GitHub runner 上真跑过**：clang 下载、`actions/cache`、产物上传等依赖 runner 的环节需要首次手动运行确认。
- **未在真机刷入验证**：验证只到"编译出 Image / 打出 AnyKernel3 包"。
- BakaSU 线 pin 在 `v4.2.0-rc3`：上游 `main` 分支目前主动禁用 SUSFS 构建（`susfs_compat.mk` 里的无条件
  `$(error Please wait susfs update.)`），待其放行后建议改用正式 tag。
- 内核内 SUSFS 的两条线，装机后还需要 userspace 工具 `ksu_susfs` 配置 `sus_path` / `sus_mount` 等（本项目不构建）。
- 同一份源码重复构建的 `Image` sha256 会不同（内核 `compile.h` 内嵌构建时间）；如需可复现请固定 `build_time`。

## 内核特性

<details>
<summary>展开查看完整特性清单</summary>

### Android 特定功能

- ✅ **Binder IPC**：`binder` / `hwbinder` / `vndbinder`
- ✅ **Ashmem**：Android 共享内存管理器
- ✅ **Low Memory Killer**：低内存杀手机制
- ✅ **Android 电源管理**：wakelocks 与 autosleep
- ✅ **USB Gadget**：ConfigFS、MIDI、FunctionFS

### 安全特性

- ✅ **SELinux**：强制访问控制
- ✅ **Hardened User Copy** / **Stack Protector Strong**
- ✅ **CPU SW Domain PAN** / **ARM64 SW TTBR0 PAN**
- ✅ **Strict Kernel RWX**、**Seccomp**、**Audit**
- ✅ **FIPS 140**（可选，见 `build.config.gki.aarch64.fips140`）

### 网络功能

- ✅ **IPv4/IPv6** 双栈
- ✅ **Netfilter**：IPTables / IP6Tables、Conntrack、NAT
- ✅ **IPSec / XFRM**：ESP、AH、隧道模式
- ✅ **HTB** 队列规则、**U32** 分类器

### 文件系统支持

- ✅ **EXT4**（带安全扩展）、**FUSE**、**TMPFS**（POSIX ACL）、**VFAT**、**MSDOS**
- ✅ **Device Mapper**：DM-Crypt、DM-Verity、DM-Verity FEC

### 模块化支持

- ✅ 内核模块加载/卸载、**MODVERSIONS**、**System DLKM**、GKI 模块规范

### 调试与性能分析

- ✅ **KASAN**（可选）、**KProbes**（可选）、**Ftrace**、**Perf Events**
- ✅ **Kallsyms**（全符号）、**Pstore**、调度统计、任务统计

### 其他

- ✅ **BPF**、**Cgroups**、RT 组调度、高精度定时器、**KASLR**
- ✅ **USB HID**、输入子系统、基础媒体与 ALSA 音频框架

</details>

## 设备支持

本项目支持多个厂商的 ABI 兼容性，包括但不限于 Pixel、Samsung、Xiaomi、OnePlus、MediaTek、Qualcomm、
Unisoc，以及 Honor、Vivo、Oppo、Sony、Motorola、Lenovo、Nothing 等。

## ABI 兼容性

GKI 内核严格遵循 **KMI（Kernel Module Interface）** 规范：

- ✅ **ABI 稳定性**：内核与模块之间的接口保持稳定
- ✅ **向后兼容**：新版本内核兼容旧版本模块
- ✅ **符号导出控制**：仅导出允许的符号（`KMI_SYMBOL_LIST_ADD_ONLY=1`、`KMI_ENFORCED=1`）
- ✅ **类型可见性**：`android/abi_gki_aarch64_type_visibility`

相关文件：

- `android/abi_gki_aarch64`：基础 KMI 符号列表
- `android/abi_gki_aarch64_*.xml`：各厂商特定的 ABI 定义
- `build.config.common`：`KMI_GENERATION=8`

## 项目结构

```
android_gki_kernel_5.15_common/
├── .github/
│   ├── workflows/              # CI 工作流（3 条 KSU/SUSFS + 2 条 Bazel + 清理）
│   └── scripts/                # 本地清理脚本
├── android/                    # Android 特定文件（KMI 符号列表等）
├── anykernel_template/         # AnyKernel3 刷机模板
├── arch/arm64/                 # ARM64 架构支持
├── build.config.*              # 构建配置（工具链版本见 build.config.constants）
├── build_gki.sh                # 本地构建脚本
├── drivers/ kernel/ fs/ net/ security/
├── Documentation/              # 内核文档
└── CCACHE_SETUP.md             # ccache 配置说明
```

## 开发指南

### 提交补丁

1. **最佳方式**：向上游 Linux 内核提交补丁
2. **补丁标签**：`UPSTREAM:` / `BACKPORT:` / `FROMGIT:` / `FROMLIST:` / `ANDROID:`
3. **必需标签**：`Change-Id:`、`Signed-off-by:`、`Bug:`（如适用）

### 代码规范

- 遵循 Linux 内核编码规范，通过 `scripts/checkpatch.pl` 检查
- 不破坏 `gki_defconfig` 或 `allmodconfig` 构建
- 修改内核代码时注意保持 KMI 兼容性，否则可能导致模块加载失败

## 许可证

本项目遵循 **GPL-2.0** 许可证，详见 `COPYING` 文件。

## 相关资源

- 官方文档：<https://source.android.com/docs/core/architecture/kernel>
- GKI 规范：<https://source.android.com/docs/core/architecture/kernel/generic-kernel-image>
- 上游内核：<https://www.kernel.org/>
- KernelSU：<https://github.com/tiann/KernelSU> ｜ KernelSU-Next：<https://github.com/KernelSU-Next/KernelSU-Next>
- BakaSU：<https://github.com/Baka-SU/BakaSU> ｜ susfs4ksu：<https://gitlab.com/simonpunk/susfs4ksu>

---

**最后更新**：2026-10-17
