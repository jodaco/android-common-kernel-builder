# How to Build Android Common Kernels (x86_64) with a Custom Config

This documents the manual steps to check out and build each Android common kernel
version with a custom `BUILD_CONFIG` that enables KASAN, KCOV, debug options, and
cuttlefish virtual device modules.

The build system changed across versions:
- **Android 12 & 13**: `build/build.sh` with `BUILD_CONFIG=<path>`
- **Android 14, 15, 16**: Bazel only (`tools/bazel`) with `user.bazelrc` + `custom/` overlay

---

## Android 12 Common Kernel (5.10)

### Build system

Android 12 uses `build/build.sh` with a `BUILD_CONFIG` file.

### Custom config file

Save the following as `my-x86-config` **next to** the checkout directory (not inside it):

```bash
KERNEL_DIR=common

. ${ROOT_DIR}/${KERNEL_DIR}/build.config.gki.x86_64

# Relax KMI enforcement
KMI_ENFORCED=0
TRIM_NONLISTED_KMI=0
KMI_SYMBOL_LIST_STRICT_MODE=0

# Cuttlefish virtual device support
BUILD_INITRAMFS=1
EXT_MODULES="common-modules/virtual-device"
LZ4_RAMDISK=1
BUILD_GOLDFISH_DRIVERS=m
MODULES_OPTIONS="options mac80211_hwsim radios=0"

POST_DEFCONFIG_CMDS="${POST_DEFCONFIG_CMDS} && update_syzbot2ftrace_config"

function update_syzbot2ftrace_config() {
  # Merge virtual device module kconfig fragment
  KCONFIG_CONFIG=${OUT_DIR}/.config \
    ${ROOT_DIR}/${KERNEL_DIR}/scripts/kconfig/merge_config.sh -m -r \
    ${OUT_DIR}/.config \
    ${ROOT_DIR}/common-modules/virtual-device/virtual_device.fragment

  # KASAN + debug + syzkaller config
  ${KERNEL_DIR}/scripts/config --file ${OUT_DIR}/.config \
    -e CONFIG_KASAN \
    -e CONFIG_KASAN_GENERIC \
    -e CONFIG_KASAN_OUTLINE \
    -e CONFIG_KCOV \
    -e CONFIG_KCOV_INSTRUMENT_ALL \
    -e CONFIG_KCOV_ENABLE_COMPARISONS \
    -e CONFIG_DEBUG_INFO \
    -d CONFIG_RANDOMIZE_BASE \
    -e CONFIG_SLUB \
    -e CONFIG_SLUB_DEBUG \
    -d CONFIG_SLUB_DEBUG_ON \
    -d CONFIG_SLUB_DEBUG_PANIC_ON \
    -e CONFIG_DEBUG_FS \
    -e CONFIG_KALLSYMS \
    -e CONFIG_KALLSYMS_ALL \
    -e CONFIG_CONFIGFS_FS \
    -e CONFIG_SECURITYFS \
    -e CONFIG_FAULT_INJECTION \
    -e CONFIG_FAULT_INJECTION_DEBUG_FS \
    -e CONFIG_FAULT_INJECTION_USERCOPY \
    -e CONFIG_FAILSLAB \
    -e CONFIG_FAIL_PAGE_ALLOC \
    -e CONFIG_FAIL_MAKE_REQUEST \
    -e CONFIG_FAIL_IO_TIMEOUT \
    -e CONFIG_FAIL_FUTEX \
    -e CONFIG_USB_RAW_GADGET \
    -e CONFIG_CHECKPOINT_RESTORE \
    --set-val CONFIG_FRAME_WARN 0 \
    -d LTO_CLANG_THIN \
    -d LTO_CLANG_FULL \
    -d CFI_PERMISSIVE \
    -d CFI_CLANG \
    -d SHADOW_CALL_STACK

  (cd ${OUT_DIR} && \
   make ${CC_LD_ARG} O=${OUT_DIR} olddefconfig)
}
```

### How to build

```bash
# Directory layout:
#   my-x86-config                          <-- config file
#   android12-5.10-2025-02_r2/             <-- kernel checkout
#     common/
#     common-modules/virtual-device/
#     build/build.sh

cd android12-5.10-2025-02_r2
BUILD_CONFIG=../my-x86-config build/build.sh
```

### Output

Build artifacts land in `out/<branch>/dist/`:
- `bzImage` -- bootable kernel
- `vmlinux` -- unstripped kernel (for symbolization)
- `initramfs.img` -- initial ramdisk with virtual device modules
- `*.ko` -- kernel modules

### Key differences from Android 13

| Aspect | Android 12 | Android 13 |
|--------|-----------|-----------|
| olddefconfig invocation | `${CC_LD_ARG}` | `${TOOL_ARGS}` |
| `CC_LD_ARG` available? | Yes (legacy alias for TOOL_ARGS) | Removed |

---

## Android 13 Common Kernel (5.10 and 5.15)

### Build system

Android 13 also uses `build/build.sh` with `BUILD_CONFIG`. The script at
`build/build.sh` is a symlink to `kernel/build.sh` -- both work.

### Custom config file

The config is identical to Android 12 **except** for the `olddefconfig` line.
Android 13 removed the `CC_LD_ARG` alias; use `TOOL_ARGS` instead.

Save as `my-x86-config`:

```bash
KERNEL_DIR=common

. ${ROOT_DIR}/${KERNEL_DIR}/build.config.gki.x86_64

# Relax KMI enforcement
KMI_ENFORCED=0
TRIM_NONLISTED_KMI=0
KMI_SYMBOL_LIST_STRICT_MODE=0

# Cuttlefish virtual device support
BUILD_INITRAMFS=1
EXT_MODULES="common-modules/virtual-device"
LZ4_RAMDISK=1
BUILD_GOLDFISH_DRIVERS=m
MODULES_OPTIONS="options mac80211_hwsim radios=0"

POST_DEFCONFIG_CMDS="${POST_DEFCONFIG_CMDS} && update_syzbot2ftrace_config"

function update_syzbot2ftrace_config() {
  # Merge virtual device module kconfig fragment
  KCONFIG_CONFIG=${OUT_DIR}/.config \
    ${ROOT_DIR}/${KERNEL_DIR}/scripts/kconfig/merge_config.sh -m -r \
    ${OUT_DIR}/.config \
    ${ROOT_DIR}/common-modules/virtual-device/virtual_device.fragment

  # KASAN + debug + syzkaller config
  ${KERNEL_DIR}/scripts/config --file ${OUT_DIR}/.config \
    -e CONFIG_KASAN \
    -e CONFIG_KASAN_GENERIC \
    -e CONFIG_KASAN_OUTLINE \
    -e CONFIG_KCOV \
    -e CONFIG_KCOV_INSTRUMENT_ALL \
    -e CONFIG_KCOV_ENABLE_COMPARISONS \
    -e CONFIG_DEBUG_INFO \
    -d CONFIG_RANDOMIZE_BASE \
    -e CONFIG_SLUB \
    -e CONFIG_SLUB_DEBUG \
    -d CONFIG_SLUB_DEBUG_ON \
    -d CONFIG_SLUB_DEBUG_PANIC_ON \
    -e CONFIG_DEBUG_FS \
    -e CONFIG_KALLSYMS \
    -e CONFIG_KALLSYMS_ALL \
    -e CONFIG_CONFIGFS_FS \
    -e CONFIG_SECURITYFS \
    -e CONFIG_FAULT_INJECTION \
    -e CONFIG_FAULT_INJECTION_DEBUG_FS \
    -e CONFIG_FAULT_INJECTION_USERCOPY \
    -e CONFIG_FAILSLAB \
    -e CONFIG_FAIL_PAGE_ALLOC \
    -e CONFIG_FAIL_MAKE_REQUEST \
    -e CONFIG_FAIL_IO_TIMEOUT \
    -e CONFIG_FAIL_FUTEX \
    -e CONFIG_USB_RAW_GADGET \
    -e CONFIG_CHECKPOINT_RESTORE \
    --set-val CONFIG_FRAME_WARN 0 \
    -d LTO_CLANG_THIN \
    -d LTO_CLANG_FULL \
    -d CFI_PERMISSIVE \
    -d CFI_CLANG \
    -d SHADOW_CALL_STACK

  (cd ${OUT_DIR} && \
   make ${TOOL_ARGS} O=${OUT_DIR} olddefconfig)
}
```

### How to build

```bash
cd android13-5.10-2025-01_r3    # or android13-5.15-2025-01_r7
BUILD_CONFIG=../my-x86-config build/build.sh
```

### 5.10 vs 5.15 differences

The config file above works for **both** 5.10 and 5.15. The build command is
identical. The only difference is in the kernel source itself (different
defconfig defaults, different module sets), but the build system and config
format are the same.

| Aspect | android13-5.10 | android13-5.15 |
|--------|---------------|---------------|
| Config file | Same | Same |
| Build command | `BUILD_CONFIG=... build/build.sh` | `BUILD_CONFIG=... build/build.sh` |
| `TOOL_ARGS` | Yes | Yes |
| `virtual_device.fragment` | Yes | Yes |
| `virtual_device_core.fragment` | No | No |

---

## Android 14 Common Kernel (5.15 and 6.1)

### Build system

Android 14 switched to **Bazel only** (Kleaf). There is no `build/build.sh`.

The bazel target `//common-modules/virtual-device:virtual_device_x86_64_dist`
builds the kernel, virtual device modules, and initramfs all together.

### Drop-in bazel overlay (recommended approach)

Kleaf auto-imports `user.bazelrc` from the workspace root via
`try-import %workspace%/user.bazelrc` in `build/kernel/kleaf/common.bazelrc`.

Create a `custom/` directory at the workspace root with a defconfig fragment,
and a `user.bazelrc` to wire it in. **No existing files are modified.**

**IMPORTANT**: The old `GKI_BUILD_CONFIG_FRAGMENT` approach with
`POST_DEFCONFIG_CMDS` shell functions does NOT work with Kleaf. Kleaf reads
build config variables (like `LTO=none`) but does not execute shell functions.
Kconfig options set via `scripts/config` in a shell function will silently
never be applied.

#### Tree layout

```
android14-6.1-2025-05_r9/
├── WORKSPACE
├── user.bazelrc              <-- drop-in (auto-imported by kleaf)
├── custom/                   <-- drop-in
│   ├── BUILD.bazel
│   └── syzbot2ftrace_defconfig
├── common/                   # kernel source (unmodified)
├── common-modules/
└── ...
```

#### user.bazelrc

```
build:custom --lto=none
build:custom --notrim
build:custom --nokmi_symbol_list_strict_mode
build:custom --defconfig_fragment=//custom:syzbot2ftrace_defconfig
```

The flags are guarded behind `--config=custom` so a plain `tools/bazel run`
gives a stock build. Pass `--config=custom` to activate.

#### custom/BUILD.bazel

```python
exports_files(["syzbot2ftrace_defconfig"])
```

**Note**: Must use `exports_files`, NOT `filegroup`. A `filegroup` creates a
dependency cycle because `--defconfig_fragment` is a global `label_flag` that
applies to all targets including the filegroup itself.

#### custom/syzbot2ftrace_defconfig

Raw kconfig fragment (not a shell script):

```
CONFIG_KASAN=y
CONFIG_KASAN_GENERIC=y
CONFIG_KASAN_OUTLINE=y
CONFIG_KCOV=y
CONFIG_KCOV_INSTRUMENT_ALL=y
CONFIG_KCOV_ENABLE_COMPARISONS=y
CONFIG_DEBUG_INFO=y
# CONFIG_RANDOMIZE_BASE is not set
CONFIG_SLUB=y
CONFIG_SLUB_DEBUG=y
# CONFIG_SLUB_DEBUG_ON is not set
# CONFIG_SLUB_DEBUG_PANIC_ON is not set
CONFIG_DEBUG_FS=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_CONFIGFS_FS=y
CONFIG_SECURITYFS=y
CONFIG_FAULT_INJECTION=y
CONFIG_FAULT_INJECTION_DEBUG_FS=y
CONFIG_FAULT_INJECTION_USERCOPY=y
CONFIG_FAILSLAB=y
CONFIG_FAIL_PAGE_ALLOC=y
CONFIG_FAIL_MAKE_REQUEST=y
CONFIG_FAIL_IO_TIMEOUT=y
CONFIG_FAIL_FUTEX=y
CONFIG_USB_RAW_GADGET=y
CONFIG_CHECKPOINT_RESTORE=y
CONFIG_FRAME_WARN=0
```

### How to build

```bash
cd android14-6.1-2025-05_r9

# Drop the overlay files into the workspace root
cp /path/to/user.bazelrc .
cp -r /path/to/custom .

# Build with custom config (KASAN, KCOV, debug options, LTO=none)
tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist

# Or build stock (without custom config)
tools/bazel run //common-modules/virtual-device:virtual_device_x86_64_dist
```

### Verifying config was applied

```bash
# From build output
common/scripts/extract-ikconfig out/*/dist/vmlinux | grep -E "KASAN|KCOV"

# Or after booting in cuttlefish
adb shell zcat /proc/config.gz | grep -E "CONFIG_KASAN_GENERIC=y|CONFIG_KCOV=y"
```

### Available Kleaf flags

From `build/kernel/kleaf/bazelrc/flags.bazelrc`:

| Flag | What it does |
|------|-------------|
| `--lto=none` | Disable LTO (also `thin`, `full`, `default`) |
| `--kasan` | Enable KASAN (native kleaf support) |
| `--notrim` | Disable KMI trimming |
| `--nokmi_symbol_list_strict_mode` | Disable strict KMI symbol checking |
| `--defconfig_fragment=//label` | Merge a kconfig fragment into .config |
| `--gcov` | Enable GCOV |
| `--kcsan` | Enable KCSAN |

### Output

Build artifacts land in `out/virtual_device_x86_64/dist/` (different from android12/13):
- `bzImage` -- bootable kernel
- `vmlinux` -- unstripped kernel
- `initramfs.img` -- initial ramdisk with virtual device modules
- `*.ko` -- kernel modules

---

## Android 15 Common Kernel (6.6)

### Build system

Same as Android 14 — Bazel/Kleaf with `tools/bazel`. The `user.bazelrc` + `custom/`
overlay approach is identical.

### Bazel overlay

The overlay files are **identical** to Android 14:

- `user.bazelrc` — same flags (`--lto=none`, `--notrim`, `--nokmi_symbol_list_strict_mode`, `--defconfig_fragment`)
- `custom/BUILD.bazel` — same `exports_files(["syzbot2ftrace_defconfig"])`
- `custom/syzbot2ftrace_defconfig` — same kconfig fragment (KASAN, KCOV, debug options)

See [Android 14 section](#drop-in-bazel-overlay-recommended-approach) for the full file contents.

### How to build

```bash
cd android15-6.6-2026-01_r1

# Drop the overlay files into the workspace root
cp /path/to/user.bazelrc .
cp -r /path/to/custom .

# Build with custom config
tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist
```

### Kernel patch notes (6.6)

The syzbot2ftrace patch for 6.6 modifies the same 7 files as all other versions.
Key differences from 6.1:

| Aspect | 6.1 (android14) | 6.6 (android15) |
|--------|-----------------|-----------------|
| `security_sid_to_context` | `(state, ssid, &scontext, &scontext_len)` | `(ssid, &scontext, &scontext_len)` — `state` param removed |
| LSM hook dispatch | `hlist_for_each_entry` | Same |
| LSM name access | `P->lsm` | Same |
| Audit context | `AUDIT_CTX_SYSCALL` | Same |

---

## Android 16 Common Kernel (6.12)

### Build system

Same as Android 14/15 — Bazel/Kleaf with `tools/bazel`. The `user.bazelrc` + `custom/`
overlay approach is identical.

### Bazel overlay

The overlay files are **identical** to Android 14 and 15. See
[Android 14 section](#drop-in-bazel-overlay-recommended-approach) for the full file contents.

### How to build

```bash
cd android16-6.12-2025-12_r1

# Drop the overlay files into the workspace root
cp /path/to/user.bazelrc .
cp -r /path/to/custom .

# Build with custom config
tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist
```

### Kernel patch notes (6.12)

The 6.12 kernel rewrote the LSM hook dispatch mechanism from linked lists to
static calls. This is the most significant patch difference across all versions.

| Aspect | 6.6 (android15) | 6.12 (android16) |
|--------|-----------------|------------------|
| LSM hook dispatch | `hlist_for_each_entry(P, ...)` | Static calls (`LSM_LOOP_UNROLL`) |
| LSM name access | `P->lsm` | `static_calls_table.HOOK[NUM].hl->lsmid->name` |
| Hook macros | `call_void_hook` / `call_int_hook` | `__CALL_STATIC_VOID` / `__CALL_STATIC_INT` |
| Error check | `RC != 0` | `R != LSM_RET_DEFAULT(HOOK)` |
| `security_sid_to_context` | `(ssid, ...)` (no state) | Same as 6.6 |
| Audit context | `AUDIT_CTX_SYSCALL` | Same |

The `security/security.c` patch is completely rewritten for 6.12 to work with
the static calls architecture, while the other 6 files remain structurally
similar across all versions.

---

## Summary

### Build system per version

| Version | Build System | Build Command |
|---------|-------------|---------------|
| android12-5.10 | `build/build.sh` | `BUILD_CONFIG=../config build/build.sh` |
| android13-5.10 | `build/build.sh` | Same as android12 |
| android13-5.15 | `build/build.sh` | Same as android12 |
| android14-5.15 | `tools/bazel` | `tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist` |
| android14-6.1 | `tools/bazel` | Same as android14-5.15 |
| android15-6.6 | `tools/bazel` | Same as android14 |
| android16-6.12 | `tools/bazel` | Same as android14 |

### Config approach per version

| Version | Config Approach | Key Difference |
|---------|----------------|----------------|
| android12 | `BUILD_CONFIG` (standalone file, outside tree) | `${CC_LD_ARG}` for olddefconfig |
| android13 | `BUILD_CONFIG` (standalone file, outside tree) | `${TOOL_ARGS}` for olddefconfig |
| android14/15/16 | `user.bazelrc` + `custom/` (copied into tree) | `--lto=none` flag, defconfig fragment |

### Patch differences across kernel versions

| Aspect | 5.10 | 5.15 | 6.1 | 6.6 | 6.12 |
|--------|------|------|-----|-----|------|
| `avc_audit` trailing `, 0` | YES | NO | NO | NO | NO |
| Audit context | `in_syscall=1` | `in_syscall=1` | `AUDIT_CTX_SYSCALL` | Same as 6.1 | Same as 6.1 |
| Audit state enum | `AUDIT_DISABLED` | `AUDIT_STATE_DISABLED` | `AUDIT_STATE_DISABLED` | Same as 6.1 | Same as 6.1 |
| `security_sid_to_context` | `(state, ssid, ...)` | Same | Same | `(ssid, ...)` | Same as 6.6 |
| LSM hook dispatch | `hlist_for_each_entry` | Same | Same | Same | Static calls |
| LSM name access | `P->lsm` | Same | Same | Same | `static_calls_table...lsmid->name` |

### Files modified by each patch (7 files, all versions)

1. `kernel/entry/common.c` — pass args[4], args[5] to audit_syscall_entry
2. `include/linux/audit.h` — extend `__audit_syscall_entry` declaration + inline wrapper
3. `include/uapi/linux/audit.h` — add `AUDIT_ARG4`, `AUDIT_ARG5`
4. `kernel/audit.h` — argv array from 4 to 6 elements
5. `kernel/auditsc.c` — filter rules, log format, `__audit_syscall_entry` impl
6. `security/security.c` — hook dispatch debug tracing (`security_capable`, `call_void_hook`, `call_int_hook`)
7. `security/selinux/avc.c` — AVC debug logging for process "repro"
