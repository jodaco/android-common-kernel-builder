#!/usr/bin/env bash
# Patch application and kernel build.
# Requires: common.sh sourced first.

BUILD_IMAGE="${BUILD_IMAGE:-common-kernel-builder}"

ensure_build_image() {
    _ensure_image "$BUILD_IMAGE" "Dockerfile.kernel-builder"
}

# Run build.sh inside Docker container.
docker_build() {
    local kernel_tag="$1"
    local android_major kernel_version config_rel

    android_major=$(get_android_major "$kernel_tag")
    kernel_version=$(get_kernel_version "$kernel_tag")
    config_rel="../kernel-configs/$android_major/${android_major}-${kernel_version}-x86-config"

    ensure_build_image || return 1

    local tag_dir="$BASE_DIR/$kernel_tag"

    log_indent "Building in Docker: $kernel_tag"
    docker run --rm \
        --ulimit nofile=65536:65536 \
        -v "$tag_dir:/workspace/$kernel_tag" \
        -v "$CONFIGS_DIR:/workspace/kernel-configs:ro" \
        -w "/workspace/$kernel_tag" \
        "$BUILD_IMAGE" \
        bash -c "BUILD_CONFIG='$config_rel' build/build.sh; sudo chown -R \$(id -u):\$(id -g) out/ 2>/dev/null || true" \
        2>&1 | tee "/tmp/build-${kernel_tag}.log"

    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -ne 0 ]; then
        log_indent "ERROR: Docker build failed (exit code $exit_code)"
        return 1
    fi

    log_indent "Docker build succeeded"
    return 0
}

# Run bazel build inside Docker container (android14+).
# Drops user.bazelrc + custom/ overlay into tree for defconfig fragment.
# Output: out/virtual_device_x86_64/dist/
docker_bazel_build() {
    local kernel_tag="$1"
    local android_major

    android_major=$(get_android_major "$kernel_tag")
    local overlay_dir="$CONFIGS_DIR/$android_major"

    if [ ! -f "$overlay_dir/user.bazelrc" ]; then
        log_indent "ERROR: No user.bazelrc at $overlay_dir/"
        return 1
    fi

    ensure_build_image || return 1

    local tag_dir="$BASE_DIR/$kernel_tag"

    # Drop bazel overlay into workspace root (user.bazelrc + custom/)
    cp "$overlay_dir/user.bazelrc" "$tag_dir/"
    cp -r "$overlay_dir/custom" "$tag_dir/"

    log_indent "Building in Docker (bazel): $kernel_tag"
    docker run --rm \
        --ulimit nofile=65536:65536 \
        -v "$tag_dir:/workspace/$kernel_tag" \
        -w "/workspace/$kernel_tag" \
        "$BUILD_IMAGE" \
        bash -c "
            tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist
            sudo chown -R \$(id -u):\$(id -g) out/ 2>/dev/null || true
        " 2>&1 | tee "/tmp/build-${kernel_tag}.log"

    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -ne 0 ]; then
        log_indent "ERROR: Docker bazel build failed (exit code $exit_code)"
        return 1
    fi

    log_indent "Docker bazel build succeeded"
    return 0
}

# Apply the syzbot2ftrace patch to common/.
# Uses -C1 for loose context matching across minor kernel revisions.
apply_syzbot2ftrace_patch() {
    local kernel_tag="$1"
    local tag_dir="$BASE_DIR/$kernel_tag"
    local common_dir="$tag_dir/common"
    local android_major kernel_version patch_file

    android_major=$(get_android_major "$kernel_tag")
    kernel_version=$(get_kernel_version "$kernel_tag")
    patch_file="$PATCHES_DIR/$android_major/syzbot2ftrace-${android_major}-${kernel_version}-x86.patch"

    if [ ! -f "$patch_file" ]; then
        log_indent "ERROR: No patch found at $patch_file"
        return 1
    fi

    if [ ! -d "$common_dir" ]; then
        log_indent "ERROR: No common/ directory at $common_dir"
        return 1
    fi

    log_indent "Applying patch: $(basename "$patch_file")"

    # Try to apply the patch
    if git -C "$common_dir" apply -C1 "$patch_file" 2>/dev/null; then
        log_indent "Patch applied successfully"
        return 0
    fi

    # Apply failed — check if patch is already applied (reverse applies cleanly)
    if git -C "$common_dir" apply -C1 --check -R "$patch_file" 2>/dev/null; then
        log_indent "Patch already applied, skipping"
        return 0
    fi

    # Neither forward nor reverse works — try to reverse and reapply
    # (handles partial/dirty state from a previous failed build)
    log_indent "Attempting to reverse old patch and reapply..."
    git -C "$common_dir" checkout -- . 2>/dev/null
    if git -C "$common_dir" apply -C1 "$patch_file" 2>/dev/null; then
        log_indent "Patch applied after tree cleanup"
        return 0
    fi

    log_indent "ERROR: git apply -C1 failed for $(basename "$patch_file")"
    return 1
}

# Build kernel + virtual device modules.
# Runs inside Docker for toolchain compatibility.
# Config file lives outside the tree — only tree modification is the patch.
do_build() {
    local kernel_tag="$1"
    local tag_dir="$BASE_DIR/$kernel_tag"
    local android_major kernel_version config_rel

    android_major=$(get_android_major "$kernel_tag")
    kernel_version=$(get_kernel_version "$kernel_tag")
    config_rel="../kernel-configs/$android_major/${android_major}-${kernel_version}-x86-config"

    if [ ! -f "$tag_dir/$config_rel" ]; then
        log_indent "ERROR: No build config at $(cd "$tag_dir" && realpath "$config_rel" 2>/dev/null || echo "$config_rel")"
        return 1
    fi

    if ! apply_syzbot2ftrace_patch "$kernel_tag"; then
        return 1
    fi

    # Build in Docker if available, else locally
    if command -v docker >/dev/null 2>&1; then
        docker_build "$kernel_tag"
    else
        cd "$tag_dir"
        log_indent "Building locally: BUILD_CONFIG=$config_rel build/build.sh"
        BUILD_CONFIG="$config_rel" \
            build/build.sh 2>&1 | tee "/tmp/build-${kernel_tag}.log"
        local exit_code=${PIPESTATUS[0]}
        if [ "$exit_code" -ne 0 ]; then
            log_indent "ERROR: build.sh failed (exit code $exit_code)"
            return 1
        fi
        log_indent "Build succeeded"
    fi
}

# --- Version dispatch ---
# Main script calls build_kernel() which dispatches to build_android${version}().
# All versions use the same build.sh flow; version-specific differences
# are handled in the per-version config files (kernel-configs/).

build_android12() { do_build "$1"; }
build_android13() { do_build "$1"; }

build_android14() {
    local kernel_tag="$1"

    if ! apply_syzbot2ftrace_patch "$kernel_tag"; then
        return 1
    fi

    if command -v docker >/dev/null 2>&1; then
        docker_bazel_build "$kernel_tag"
    else
        local tag_dir="$BASE_DIR/$kernel_tag"
        local android_major
        android_major=$(get_android_major "$kernel_tag")
        local overlay_dir="$CONFIGS_DIR/$android_major"
        cp "$overlay_dir/user.bazelrc" "$tag_dir/"
        cp -r "$overlay_dir/custom" "$tag_dir/"
        cd "$tag_dir"
        log_indent "Building locally (bazel): $kernel_tag"
        tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist \
            2>&1 | tee "/tmp/build-${kernel_tag}.log"
        local exit_code=${PIPESTATUS[0]}
        if [ "$exit_code" -ne 0 ]; then
            log_indent "ERROR: bazel build failed (exit code $exit_code)"
            return 1
        fi
        log_indent "Build succeeded"
    fi
}

build_android15() {
    local kernel_tag="$1"

    if ! apply_syzbot2ftrace_patch "$kernel_tag"; then
        return 1
    fi

    local tag_dir="$BASE_DIR/$kernel_tag"
    local android_major
    android_major=$(get_android_major "$kernel_tag")
    local overlay_dir="$CONFIGS_DIR/$android_major"

    if [ ! -f "$overlay_dir/user.bazelrc" ]; then
        log_indent "ERROR: No user.bazelrc at $overlay_dir/"
        return 1
    fi

    # Drop bazel overlay into workspace root (user.bazelrc + custom/)
    cp "$overlay_dir/user.bazelrc" "$tag_dir/"
    cp -r "$overlay_dir/custom" "$tag_dir/"

    if command -v docker >/dev/null 2>&1; then
        ensure_build_image || return 1

        log_indent "Building in Docker (bazel): $kernel_tag"
        docker run --rm \
            --ulimit nofile=65536:65536 \
            -v "$tag_dir:/workspace/$kernel_tag" \
            -w "/workspace/$kernel_tag" \
            "$BUILD_IMAGE" \
            bash -c "
                tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist
                sudo chown -R \$(id -u):\$(id -g) out/ 2>/dev/null || true
            " 2>&1 | tee "/tmp/build-${kernel_tag}.log"

        local exit_code=${PIPESTATUS[0]}
        if [ "$exit_code" -ne 0 ]; then
            log_indent "ERROR: Docker bazel build failed (exit code $exit_code)"
            return 1
        fi
        log_indent "Docker bazel build succeeded"
    else
        cd "$tag_dir"
        log_indent "Building locally (bazel): $kernel_tag"
        tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist \
            2>&1 | tee "/tmp/build-${kernel_tag}.log"
        local exit_code=${PIPESTATUS[0]}
        if [ "$exit_code" -ne 0 ]; then
            log_indent "ERROR: bazel build failed (exit code $exit_code)"
            return 1
        fi
        log_indent "Build succeeded"
    fi
}

build_android16() {
    local kernel_tag="$1"

    if ! apply_syzbot2ftrace_patch "$kernel_tag"; then
        return 1
    fi

    local tag_dir="$BASE_DIR/$kernel_tag"
    local android_major
    android_major=$(get_android_major "$kernel_tag")
    local overlay_dir="$CONFIGS_DIR/$android_major"

    if [ ! -f "$overlay_dir/user.bazelrc" ]; then
        log_indent "ERROR: No user.bazelrc at $overlay_dir/"
        return 1
    fi

    # Drop bazel overlay into workspace root (user.bazelrc + custom/)
    cp "$overlay_dir/user.bazelrc" "$tag_dir/"
    cp -r "$overlay_dir/custom" "$tag_dir/"

    if command -v docker >/dev/null 2>&1; then
        ensure_build_image || return 1

        log_indent "Building in Docker (bazel): $kernel_tag"
        docker run --rm \
            --ulimit nofile=65536:65536 \
            -v "$tag_dir:/workspace/$kernel_tag" \
            -w "/workspace/$kernel_tag" \
            "$BUILD_IMAGE" \
            bash -c "
                tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist
                sudo chown -R \$(id -u):\$(id -g) out/ 2>/dev/null || true
            " 2>&1 | tee "/tmp/build-${kernel_tag}.log"

        local exit_code=${PIPESTATUS[0]}
        if [ "$exit_code" -ne 0 ]; then
            log_indent "ERROR: Docker bazel build failed (exit code $exit_code)"
            return 1
        fi
        log_indent "Docker bazel build succeeded"
    else
        cd "$tag_dir"
        log_indent "Building locally (bazel): $kernel_tag"
        tools/bazel run --config=custom //common-modules/virtual-device:virtual_device_x86_64_dist \
            2>&1 | tee "/tmp/build-${kernel_tag}.log"
        local exit_code=${PIPESTATUS[0]}
        if [ "$exit_code" -ne 0 ]; then
            log_indent "ERROR: bazel build failed (exit code $exit_code)"
            return 1
        fi
        log_indent "Build succeeded"
    fi
}

build_kernel() {
    local kernel_tag="$1"
    local version
    version=$(get_android_version "$kernel_tag")

    if [ -z "$version" ]; then
        log_indent "Could not determine Android version from $kernel_tag"
        return 1
    fi

    local build_func="build_android${version}"
    if declare -f "$build_func" > /dev/null 2>&1; then
        log "Building: $kernel_tag (using $build_func)"
        "$build_func" "$kernel_tag"
    else
        log_indent "No build function '$build_func' for $kernel_tag"
        return 1
    fi
}
