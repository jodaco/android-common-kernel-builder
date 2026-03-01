# Android Common Kernels - Fetch, Build & Boot-Test

## Current Status

- [x] Script scaffolding with CSV parsing, logging, results tracking
- [x] repo init + repo sync for individual kernel tags
- [x] Mirror infrastructure (repo init --mirror, 60-min timeout, 3 retries)
- [x] --init-mirrors flag to create/refresh mirrors independently
- [x] Auto-detect and init missing mirrors on normal run
- [x] --reference support for fast tag checkouts from local mirrors
- [x] x86 kernel patches (7 targets, all verified apply/revert cleanly)
- [x] x86 kernel configs with cuttlefish virtual device modules
- [x] build-env/ modular architecture (common, mirrors, fetch, build, cuttlefish, artifacts)
- [x] Custom BUILD_CONFIG approach (sources gki.x86_64, no tree modification)
- [x] android12-5.10 full pipeline verified (fetch, build, boot, artifact collection) — all 13 tags
- [x] android14-5.15 full pipeline verified (bazel build, cuttlefish boot, patch traces confirmed)
- [x] Docker integration: separate images for kernel building and cuttlefish runtime
- [x] Docker builds: granular mounts (tag dir rw, kernel-configs ro)
- [x] Cuttlefish boot test: launch_cvd + crash detection + adb root/su fallback + repro test
- [x] Artifact collection: dist/ → zip → build-output/, checkout cleanup
- [x] test-programs/repro: NDK binary that exercises kernel security patches at runtime
- [x] Per-kernel-version cuttlefish artifacts (cf/android13/510/, cf/android13/515/)
- [x] --tag flag for force rebuild of specific kernel tags
- [x] --disable-cleanup flag to leave checkout directories in place
- [x] --fetch-only flag for fetching without build (leaves checkout ready)
- [x] --init-mirrors implemented (single common-android-mainline mirror)
- [x] android15-6.6 full pipeline support (bazel, configs, patch, build_android15())
- [x] android15-6.6 kernel patch (native, 7 files, clean apply/revert, security_sid_to_context API fix for 6.6)
- [x] android16-6.12 full pipeline support (bazel, configs, patch, build_android16())
- [x] android16-6.12 kernel patch (native, 7 files, security.c rewritten for static calls LSM architecture)
- [x] android16-6.12 kernel configs (user.bazelrc + custom/ overlay, copied from android15)
- [x] android15-6.6 full pipeline verified (bazel build, cuttlefish boot, CVD_INSTANCE=10 for TAP devices)
- [x] android16-6.12 full pipeline verified (bazel build, cuttlefish boot)
- [x] android14-6.1 full pipeline verified (15 tags in build-output)
- [x] android13-5.15 full pipeline verified (14 tags in build-output)
- [x] android13 cuttlefish boot fix: MODULES_LIST="" clears GKI's gki_system_dlkm_modules filter
- [x] android13-5.10 full pipeline verified (14 tags in build-output)

## Architecture

### Directory Layout

```
fetch-and-build-common-kernels.sh    # thin wrapper: source build-env/*, main loop

build-env/
├── common.sh           # BASE_DIR, paths, logging, result tracking, tag helpers, _ensure_image()
├── mirrors.sh          # mirror init/sync/ensure
├── fetch.sh            # repo init/sync for individual kernel tags
├── build.sh            # Docker build functions, patch apply, kernel build dispatch
├── cuttlefish.sh       # cuttlefish boot test only (ensure_cuttlefish_image, boot_test)
├── artifacts.sh        # collect + zip build outputs
├── Dockerfile.kernel-builder   # ubuntu:24.04 with kernel build deps
└── Dockerfile.cuttlefish       # ubuntu:24.04 with cuttlefish runtime deps

test-programs/
├── repro.c             # NDK test program (exercises kernel security patches)
└── repro               # compiled static x86_64 binary (android31)

kernel-patches/         # per-version x86 unified diff patches
├── android12/
├── android13/
├── android14/
├── android15/
└── android16/

kernel-configs/         # per-version build configs
├── android12/android12-5.10-x86-config   # BUILD_CONFIG (standalone, CC_LD_ARG)
├── android13/android13-5.10-x86-config   # BUILD_CONFIG (standalone, TOOL_ARGS)
├── android13/android13-5.15-x86-config   # BUILD_CONFIG (standalone, TOOL_ARGS)
├── android14/{user.bazelrc,custom/}      # bazel overlay (--config=custom)
├── android15/{user.bazelrc,custom/}      # bazel overlay (--config=custom)
└── android16/{user.bazelrc,custom/}      # bazel overlay (--config=custom)

cf/                     # cuttlefish host packages + system images
├── android12/          # flat: cvd-host_package.tar.gz + aosp_cf_x86_64_phone-img*.zip
├── android13/
│   ├── 510/            # version-specific cf artifacts for 5.10 kernels
│   └── 515/            # version-specific cf artifacts for 5.15 kernels
├── android14/          # flat (single version for now)
├── android15/          # flat: cvd-host_package.tar.gz + aosp_cf_x86_64_only_phone-img.zip
└── android16/          # flat: cvd-host_package.tar.gz + aosp_cf_x86_64_only_phone-img.zip

mirrors/                # single unified repo mirror (common-android-mainline)
build-output/           # final artifacts: <kernel_tag>.zip containing dist/
```

### Module Responsibilities

| File | Responsibilities |
|------|-----------------|
| common.sh | BASE_DIR, paths, logging, result tracking, tag parsing helpers, `_ensure_image()` |
| build.sh | `BUILD_IMAGE`, `ensure_build_image()`, `docker_build()`, `docker_bazel_build()`, `apply_syzbot2ftrace_patch()`, `do_build()`, `build_android{12,13,14,15,16}()`, `build_kernel()` |
| cuttlefish.sh | `CUTTLEFISH_IMAGE`, `ensure_cuttlefish_image()`, `boot_test()` |
| artifacts.sh | `collect_artifacts()` |
| mirrors.sh | mirror init/sync/ensure |
| fetch.sh | repo init/sync for individual tags |

### Pipeline Flow

For each kernel_tag in the CSV:

```
1. FETCH      repo init + repo sync (with --reference to mirror)
2. PATCH      git apply -C1 <version-specific patch> to common/
3. BUILD      docker run: build/build.sh (android12/13) or tools/bazel (android14/15/16)
4. BOOT TEST  docker run: launch_cvd + adb + repro test + dmesg capture → test.log
5. COLLECT    zip dist/ → build-output/<kernel_tag>.zip
6. CLEANUP    stop_cvd, rm checkout dir, record result to fetch-results.csv
```

## Kernel Patches (kernel-patches/)

All patches extend audit syscall args (4→6), add LSM hook debug tracing,
and add SELinux AVC debug logging for process "repro". Generated via
`git diff` against actual kernel checkouts.

| Patch File | Kernel | Notes |
|-----------|--------|-------|
| android12/syzbot2ftrace-android12-5.10-x86.patch | 5.10 | avc_audit has trailing `, 0` |
| android13/syzbot2ftrace-android13-5.10-x86.patch | 5.10 | Same as android12-5.10 |
| android13/syzbot2ftrace-android13-5.15-x86.patch | 5.15 | avc_audit without trailing `, 0` |
| android14/syzbot2ftrace-android14-5.15-x86.patch | 5.15 | Same as android13-5.15 |
| android14/syzbot2ftrace-android14-6.1-x86.patch | 6.1 | Uses AUDIT_CTX_SYSCALL |
| android15/syzbot2ftrace-android15-6.6-x86.patch | 6.6 | security_sid_to_context lost `state` param |
| android16/syzbot2ftrace-android16-6.12-x86.patch | 6.12 | LSM hooks use static calls instead of hlist |

### Version-specific differences

| Aspect | 5.10 | 5.15 | 6.1 | 6.6 | 6.12 |
|--------|------|------|-----|-----|------|
| avc_audit trailing `, 0` | YES | NO | NO | NO | NO |
| audit context state | `context->in_syscall=1` | `context->in_syscall=1` | `context->context=AUDIT_CTX_SYSCALL` | Same as 6.1 | Same as 6.1 |
| audit state enum | `AUDIT_DISABLED` | `AUDIT_STATE_DISABLED` | `AUDIT_STATE_DISABLED` | Same as 6.1 | Same as 6.1 |
| security_sid_to_context | `(state, ssid, ...)` | Same | Same | `(ssid, ...)` (no state) | Same as 6.6 |
| LSM hook dispatch | hlist_for_each_entry | Same | Same | Same | static calls (LSM_LOOP_UNROLL) |
| LSM name access | `P->lsm` | Same | Same | Same | `static_calls_table.HOOK[NUM].hl->lsmid->name` |

### Files modified by each patch (7 files)

1. kernel/entry/common.c — pass args[4], args[5] to audit_syscall_entry
2. include/linux/audit.h — extend __audit_syscall_entry declaration + inline wrapper
3. include/uapi/linux/audit.h — add AUDIT_ARG4, AUDIT_ARG5
4. kernel/audit.h — argv[4] → argv[6]
5. kernel/auditsc.c — filter rules, log format, __audit_syscall_entry impl
6. security/security.c — call_void_hook, call_int_hook, security_capable debug
7. security/selinux/avc.c — includes + avc_has_perm debug block

## Kernel Configs (kernel-configs/)

### android12/android13 configs (BUILD_CONFIG, standalone)

Complete BUILD_CONFIG files that:
1. Set `KERNEL_DIR=common`
2. Source `${ROOT_DIR}/${KERNEL_DIR}/build.config.gki.x86_64` (imports full GKI chain)
3. Relax KMI enforcement (`KMI_ENFORCED=0`, `TRIM_NONLISTED_KMI=0`)
4. Enable cuttlefish virtual device modules (`EXT_MODULES`, `BUILD_INITRAMFS`, etc.)
5. Append `update_syzbot2ftrace_config` to POST_DEFCONFIG_CMDS chain
6. Merge virtual_device.fragment then apply KASAN/KCOV/debug options

### android14/android15/android16 configs (bazel with --config=custom)

Bazel overlay approach — `user.bazelrc` + `custom/` directory copied into workspace root:
1. `user.bazelrc`: `--lto=none --notrim --nokmi_symbol_list_strict_mode --defconfig_fragment=//custom:syzbot2ftrace_defconfig`
2. `custom/BUILD.bazel` + `custom/syzbot2ftrace_defconfig`: defconfig fragment with KASAN/KCOV/debug options
3. Build via `tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist`

### Build system per version (verified against actual trees)

| Version | Build system | Build command |
|---------|-------------|---------------|
| android12-5.10 | `build/build.sh` | `BUILD_CONFIG=../kernel-configs/... build/build.sh` |
| android13-5.10 | `build/build.sh` | `BUILD_CONFIG=../kernel-configs/... build/build.sh` |
| android13-5.15 | `build/build.sh` | `BUILD_CONFIG=../kernel-configs/... build/build.sh` |
| android14-5.15 | `tools/bazel` (kleaf) | `tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist` |
| android14-6.1 | `tools/bazel` (kleaf) | Same as android14-5.15 |
| android15-6.6 | `tools/bazel` (kleaf) | Same as android14 (--config=custom with user.bazelrc + custom/ overlay) |
| android16-6.12 | `tools/bazel` (kleaf) | Same as android14/15 |

### Version-specific config differences

| Aspect | android12 | android13 | android14/15/16 |
|--------|-----------|-----------|-----------------|
| Config type | BUILD_CONFIG (standalone) | BUILD_CONFIG (standalone) | bazel overlay (user.bazelrc + custom/) |
| olddefconfig | `${CC_LD_ARG}` | `${TOOL_ARGS}` | `${TOOL_ARGS}` |
| LTO disable | `-d LTO_CLANG_THIN/FULL` in kconfig | Same | `--lto=none` in user.bazelrc + `-d` in defconfig |
| Config location | Outside tree (`../`) | Outside tree (`../`) | Copied into workspace root |

## Docker Integration (build-env/)

### Two Docker Images

| Image | Dockerfile | Purpose |
|-------|-----------|---------|
| `common-kernel-builder` | `Dockerfile.kernel-builder` | Kernel compilation (build-essential, bison, flex, python3, etc.) |
| `common-kernel-cuttlefish` | `Dockerfile.cuttlefish` | Cuttlefish boot testing (qemu-kvm, adb, cuttlefish runtime deps) |

Both images:
- Base: `ubuntu:24.04`
- User created at build time matching host UID/GID
- Auto-built on first use via `_ensure_image()` in common.sh

### Build in Docker (build.sh)

```bash
# android12/13: build.sh with BUILD_CONFIG
docker run --rm \
  --ulimit nofile=65536:65536 \
  -v "$tag_dir:/workspace/$kernel_tag" \
  -v "$CONFIGS_DIR:/workspace/kernel-configs:ro" \
  -w "/workspace/$kernel_tag" \
  "$BUILD_IMAGE" \
  bash -c "BUILD_CONFIG='$config_rel' build/build.sh"

# android14/15/16: bazel with --config=custom (user.bazelrc + custom/ overlay)
docker run --rm \
  --ulimit nofile=65536:65536 \
  -v "$tag_dir:/workspace/$kernel_tag" \
  -w "/workspace/$kernel_tag" \
  "$BUILD_IMAGE" \
  bash -c "tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist"
```

### Cuttlefish Boot Test (cuttlefish.sh)

Boots kernel in cuttlefish, runs repro test binary, captures patch traces from dmesg.

Key features:
- Per-kernel-version cf artifacts: checks `cf/<android_major>/<kv_short>/` first, falls back to `cf/<android_major>/`
- Crash detection: polls `kill -0 $CVD_PID` to detect launch_cvd crashes immediately
- Root access: tries `adb root`, falls back to `su -c` for privileged commands
- Output: all test results written to `dist/test.log` (uname, repro output, dmesg patch traces)
- Runtime caching: per-version at `.cf-runtime/<android_major>/<kv_short>/`

```bash
docker run --rm --privileged --device /dev/kvm \
  --ulimit nofile=65536:65536 \
  -v "$dist_dir:/dist" \
  -v "$variant_dir:/cf:ro" \
  -v "$runtime_dir:/runtime" \
  -v "$BASE_DIR/test-programs:/test-programs:ro" \
  "$CUTTLEFISH_IMAGE" sh -c '...'
```

Boot test timeout: 300 seconds for adb wait-for-device.

### Artifact Collection (artifacts.sh)

Collects dist/ directory, zips as `<kernel_tag>.zip`, moves to `build-output/`, deletes checkout.

## Test Programs (test-programs/)

### repro

NDK-compiled static x86_64 binary that exercises kernel security patches:
- Sets process comm to "repro" via `prctl(PR_SET_NAME)` (triggers patch logging)
- Exercises: file ops, sockets, capabilities, SELinux, filesystem access
- Compiled: `x86_64-linux-android31-clang -static -O2 -Wall -o repro repro.c`
- Pushed to device via `adb push` during boot test, output captured in test.log

## Mirrors

Single unified mirror at `mirrors/` initialized from `common-android-mainline`.
This manifest is a superset containing all kernel projects, so it works as
`--reference` for any manifest branch (android12-5.10 through android16-6.12).

## Key Decisions

- Single unified mirror from `common-android-mainline` (superset of all kernel projects)
- Tag checkouts use `repo sync -c --no-tags` with `--reference` to mirror
- Mirror sync: 60-min timeout, 3 retries, returns failure on exhaustion
- Tag sync: 2-hour timeout, no retry, logs FAIL and continues to next row
- On fetch failure, the tag directory is deleted to avoid stale state
- x86 patches generated via git diff (not hand-crafted) for correctness
- Patches applied with `git apply -C1` for loose context matching
- CONFIG_KASAN_GENERIC for x86 (not SW_TAGS which is ARM64-only)
- No arm64 ptrace.c changes needed; kernel/entry/common.c handles x86 syscall entry
- android12/13: BUILD_CONFIG lives outside kernel tree (only tree modification is the patch)
- android14/15/16: bazel overlay (user.bazelrc + custom/) copied into workspace root
- Separate Docker images for building vs cuttlefish runtime
- Per-kernel-version cuttlefish artifacts and runtime dirs (5.10 and 5.15 need different host packages)
- `TOOL_ARGS` is a string, not an array — use `${TOOL_ARGS}` unquoted in make commands

## Known Issues

- **FIXED**: android13-5.10/5.15 cuttlefish partition stall was caused by `MODULES_LIST` from `build.config.gki.x86_64` filtering initramfs `modules.load` to only GKI system_dlkm modules (zsmalloc, zram). Virtio drivers were in the initramfs but not in modules.load, so init never loaded them. Fix: `MODULES_LIST=""` in our BUILD_CONFIG after sourcing GKI chain. Bazel builds are not affected (sets `MODULES_LIST=""` when `modules_list` attr is None).
- **FIXED**: android15+ cuttlefish crosvm fails with `AllocateOneMsi failed: Too many open files (os error 24)` under Docker's default 1024 fd limit. Causes MSI-X interrupt vector allocation failure → IPI delivery failure → soft lockup → RCU stall. Fix: `--ulimit nofile=65536:65536` on all `docker run` calls. Does not affect android12-14 cuttlefish host packages.
- **FIXED**: android15+ cuttlefish fails with `failed to create tap interface: Operation not permitted`. `cuttlefish-host-resources start` only pre-creates TAP devices for instances 1-10. CVD_INSTANCE was 99 (outside range), so `ValidateTapDevices` failed and crosvm got EPERM creating them as non-root. Fix: changed CVD_INSTANCE from 99 to 10. Does not affect android12-14 (older crosvm creates TAP devices on demand).
- android13 `config_server` crash loops with `Unable to obtain the network configuration` during boot test — related to cf version mismatch.

## Files (legacy, at project root)

- **kernel.patch** — original ARM64 audit + LSM/SELinux debug instrumentation
- **kernel-options.txt** — original build config overlay (has ARM64 KASAN_SW_TAGS)
