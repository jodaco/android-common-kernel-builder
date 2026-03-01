# Android Common Kernels - Fetch, Build & Boot-Test

Automated pipeline to fetch Android common kernel tags, apply syzbot2ftrace
instrumentation patches, build with KASAN/KCOV debug configs, boot-test in
Cuttlefish, and collect artifacts.

## Prerequisites

- `repo` (Android repo tool) installed and on PATH
- `docker` with access to `/dev/kvm` (for Cuttlefish boot tests)
- ~100GB free disk space (mirrors + kernel checkouts + build output)

## Quick Start

```bash
# 1. Initialize the unified local mirror (one-time, takes a while)
./fetch-and-build-common-kernels.sh --init-mirrors

# 2. Build a specific kernel tag
./fetch-and-build-common-kernels.sh --tag android12-5.10-2025-12_r1

# 3. Fetch a kernel checkout without building (for manual inspection)
./fetch-and-build-common-kernels.sh --fetch-only --tag android15-6.6-2026-01_r1
```

## Usage

```
./fetch-and-build-common-kernels.sh [OPTIONS]

Options:
  --init-mirrors      Initialize/refresh the unified repo mirror
  --tag TAG           Process only the specified kernel tag
  --all               Process all rows in the CSV
  --skip-cf           Skip cuttlefish boot test, collect artifacts directly
  --disable-cleanup   Leave checkout directories in place after build
  --fetch-only        Fetch only (no build/test), leaves checkout in place
  -h, --help          Show usage

Without --tag or --all, processes only the last CSV row (test mode).

The TARGETS variable at the top of the script controls which Android versions
are processed (e.g. TARGETS="android15 android16"). Only CSV rows whose
kernel_tag starts with a TARGETS prefix are included. Edit this variable to
add or remove versions.
```

### `--init-mirrors`

Creates a single unified `repo --mirror` clone from the `common-android-mainline`
manifest branch. This manifest is a superset containing all kernel projects,
so it works as `--reference` for any tag checkout (android12-5.10 through
android16-6.12). The mirror is stored in `mirrors/`.

Mirror sync uses a 60-minute timeout with 3 retries. Mirrors only need to be
initialized once; re-running refreshes the existing mirror.

### `--tag TAG`

Fetches, patches, builds, boot-tests, and collects artifacts for a single
kernel tag. The tag must exist in `android-kernel-info.csv`. Forces rebuild
even if artifacts already exist.

```bash
./fetch-and-build-common-kernels.sh --tag android14-5.15-2025-12_r1
```

### `--fetch-only`

Intended for use with `--tag`. Fetches the kernel checkout and leaves it in
place without building, testing, or cleaning up. Useful for manual inspection
or patch development.

```bash
./fetch-and-build-common-kernels.sh --fetch-only --tag android15-6.6-2026-01_r1
# Checkout is now at: ./android15-6.6-2026-01_r1/
```

### `--skip-cf`

Skips the Cuttlefish boot test and collects artifacts directly after build.
Artifacts are suffixed with `-not-tested-in-cf`.

### `--disable-cleanup`

Leaves checkout directories in place after build (normally they are removed
after artifact collection to save disk space).

### `--all`

Processes every row in the CSV sequentially. Skips tags that already have
artifacts in `build-output/`.

### Test mode (default)

With no flags, processes only the last matching row in the CSV.

## Pipeline Steps

For each kernel tag:

1. **Fetch** - `repo init` + `repo sync` with `--reference` to local mirror
2. **Patch** - `git apply -C1` the version-specific syzbot2ftrace patch to `common/`
3. **Build** - `build/build.sh` (android12/13) or `tools/bazel` (android14/15/16) inside Docker
4. **Boot test** - Launches Cuttlefish in Docker with the built kernel, runs repro test, captures dmesg
5. **Collect** - Zips `dist/` to `build-output/<tag>.zip`, removes checkout
6. **Record** - Appends fetch/build/boot results to `fetch-results.csv`

## Directory Layout

```
fetch-and-build-common-kernels.sh   # main entry point
android-kernel-info.csv             # input: kernel tags + manifest info

build-env/
  common.sh          # shared variables, logging, helpers
  mirrors.sh         # mirror init/sync/ensure
  validate.sh        # manifest ref validation against mirror
  fetch.sh           # repo init/sync for tag checkouts
  build.sh           # patch application + build dispatch
  cuttlefish.sh      # Cuttlefish boot test (separate Docker image)
  artifacts.sh       # collect + zip build outputs
  Dockerfile.kernel-builder   # ubuntu:24.04 with kernel build deps
  Dockerfile.cuttlefish       # ubuntu:24.04 with Cuttlefish runtime deps

kernel-patches/      # per-version x86 syzbot2ftrace patches
kernel-configs/      # per-version build configs + bazel overlays
test-programs/       # NDK test binary for patch verification
mirrors/             # unified local repo mirror (created by --init-mirrors)
cf/                  # Cuttlefish host packages + system images per version
build-output/        # final artifacts: <kernel_tag>.zip
fetch-results.csv    # output: per-tag fetch/build/boot results
```

## Input CSV Format

`android-kernel-info.csv` drives the pipeline. Each row is a kernel tag to process.

```
kernel_tag,commit,git_url,manifest1,manifest2
android15-6.6-2026-01_r1,<commit_sha>,<git_url>,common-android15-6.6-2026-01,common-android15-6.6
```

| Column | Used for |
|--------|----------|
| `kernel_tag` | Tag name — becomes the checkout directory name and artifact zip name |
| `commit` | Reference only (not used by the pipeline) |
| `git_url` | Reference only |
| `manifest1` | Primary manifest branch for `repo init -b` (e.g. `common-android15-6.6-2026-01`) |
| `manifest2` | Fallback manifest branch if `manifest1` fails |

The `kernel_tag` encodes the Android version, kernel version, and release date
(e.g. `android15-6.6-2026-01_r1`). The pipeline parses this to determine which
patch, config, and build function to use.

## Docker

Two Docker images are used:

| Image | Purpose |
|-------|---------|
| `common-kernel-builder` | Kernel compilation (build-essential, bison, flex, python3, etc.) |
| `common-kernel-cuttlefish` | Cuttlefish boot testing (qemu-kvm, adb, cuttlefish runtime deps) |

Both are based on `ubuntu:24.04`, match your host UID/GID, and are auto-built
on first use.

The kernel's hermetic toolchain handles compiler setup — Docker just provides
the base userspace environment.

### Docker mounts

Builds use granular mounts with least-privilege access:
- **Build (android12/13)**: tag checkout dir (rw) + `kernel-configs/` (ro)
- **Build (android14/15/16)**: tag checkout dir (rw), bazel overlay copied in
- **Boot test**: build dist dir (rw) + Cuttlefish packages (ro) + runtime dir (rw)

## Kernel Configs

### android12/android13 (BUILD_CONFIG)

Standalone `BUILD_CONFIG` files that source the upstream GKI build chain,
relax KMI enforcement, enable Cuttlefish virtual device modules, and apply
KASAN/KCOV/debug options. Config lives outside the kernel tree.

### android14/android15/android16 (bazel overlay)

Bazel `user.bazelrc` + `custom/` directory copied into workspace root.
Uses `--config=custom` with `--lto=none`, `--notrim`, and a defconfig
fragment for KASAN/KCOV/debug options.

## Cuttlefish Artifacts (`cf/`)

The boot test step requires Cuttlefish host packages and system images placed
in `cf/<android_version>/`. Each subfolder needs two files:

- `cvd-host_package.tar.gz` — Cuttlefish host tools (launch_cvd, crosvm, etc.)
- `aosp_cf_x86_64*phone-img*.zip` — AOSP system images for the virtual device

### Android 12, 13, 14 (download from ci.android.com)

Download pre-built GSI artifacts from Google's CI:

- **Android 12**: https://ci.android.com/builds/branches/aosp-android12-gsi/grid
- **Android 13**: https://ci.android.com/builds/branches/aosp-android13-gsi/grid
- **Android 14**: https://ci.android.com/builds/branches/aosp-android14-gsi/grid

Pick a recent green build, download `aosp_cf_x86_64_phone-img-*.zip` and
`cvd-host_package.tar.gz`, and place them in the corresponding `cf/` subfolder.

**Android 13 note**: android13 has separate `cf/android13/510/` and
`cf/android13/515/` subdirectories for the 5.10 and 5.15 kernel variants.
It is unclear if both need different host packages, but we treated them as
requiring separate artifacts.

### Android 15, 16 (build from AOSP source)

Android 15 and 16 require building AOSP from source with the Cuttlefish target.

```bash
# Clone AOSP (pick appropriate branch/tag)
repo init -u https://android.googlesource.com/platform/manifest -b <branch>
repo sync

# Set up build environment
source build/envsetup.sh

# Android 15 (bp1a)
lunch aosp_cf_x86_64_only_phone-bp1a-userdebug

# Android 16 (bp2a)
# lunch aosp_cf_x86_64_only_phone-bp2a-userdebug

# Build
m

# Generate the two artifacts needed:
m hosttar        # produces cvd-host_package.tar.gz
m updatepackage  # produces aosp_cf_x86_64_only_phone-img.zip
```

Place the resulting files in `cf/android15/` or `cf/android16/`.

### Directory structure

```
cf/
├── android12/          # GSI download (flat)
├── android13/
│   ├── 510/            # GSI download (5.10 kernels)
│   └── 515/            # GSI download (5.15 kernels)
├── android14/          # GSI download (flat)
├── android15/          # AOSP build (bp1a)
└── android16/          # AOSP build (bp2a)
```

## Current Support

| Version | Build System | Status |
|---------|-------------|--------|
| android12-5.10 | `build/build.sh` | Full pipeline verified (24 tags) |
| android13-5.10 | `build/build.sh` | Full pipeline verified (14 tags) |
| android13-5.15 | `build/build.sh` | Full pipeline verified (14 tags) |
| android14-5.15 | `tools/bazel` | Full pipeline verified (11 tags) |
| android14-6.1 | `tools/bazel` | Full pipeline verified (15 tags) |
| android15-6.6 | `tools/bazel` | Full pipeline verified (5 tags) |
| android16-6.12 | `tools/bazel` | Full pipeline verified (3 tags) |

## TODO

- **Generalize the pipeline** — Currently hardcoded to apply syzbot2ftrace patches,
  syzbot2ftrace kernel configs, and run the `repro` test binary. The pipeline should
  support arbitrary patches, configs, and test programs so it can be reused for
  different instrumentation or testing scenarios.
- **Move customization into CSV input** — Rather than baking patch/config/test-program
  paths into the build scripts, consider adding columns to the CSV (or a companion
  config file) that specify per-tag: which patch to apply, which kernel config overlay
  to use, and which test program (if any) to run during boot test. This would make the
  pipeline fully data-driven.
- **Support optional boot test** — Allow rows to specify no test program at all, so
  the pipeline can do build-only or build+boot without requiring a test binary.
- Simplify CSV input format (reduce unused columns, consider tag-only input)
- Clean up output logging (reduce noise, clearer progress indicators)
- Improve mirror error handling and reporting, especially for partial sync failures
