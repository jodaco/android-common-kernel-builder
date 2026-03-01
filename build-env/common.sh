#!/usr/bin/env bash
# Shared variables, logging, result tracking, and helpers.

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CSV_FILE="$BASE_DIR/android-kernel-info.csv"
MIRRORS_DIR="$BASE_DIR/mirrors"
RESULTS_FILE="$BASE_DIR/fetch-results.csv"
PATCHES_DIR="$BASE_DIR/kernel-patches"
CONFIGS_DIR="$BASE_DIR/kernel-configs"

# Android versions to process — set in fetch-and-build-common-kernels.sh.
TARGETS="${TARGETS:-}"

# --- Logging ---

log() {
    echo "=== $* ==="
}

log_indent() {
    echo "  $*"
}

# --- Result tracking ---

init_results() {
    if [ ! -f "$RESULTS_FILE" ]; then
        local header
        header=$(head -1 "$CSV_FILE")
        echo "$header,fetch_success,build_success,boot_success" > "$RESULTS_FILE"
    fi
}

record_result() {
    local raw_line="$1"
    local fetch_result="$2"
    local build_result="$3"
    local boot_result="${4:-no}"
    echo "$raw_line,$fetch_result,$build_result,$boot_result" >> "$RESULTS_FILE"
}

# --- Target filtering ---

# Check if a kernel tag matches one of the TARGETS prefixes.
is_target() {
    local kernel_tag="$1"
    local android_major
    android_major=$(echo "$kernel_tag" | sed -n 's/^\(android[0-9]*\).*/\1/p')
    [[ " $TARGETS " == *" $android_major "* ]]
}

# --- Tag parsing helpers ---

# "android12-5.10-2025-12_r1" -> "5.10"
get_kernel_version() {
    local kernel_tag="$1"
    echo "$kernel_tag" | sed -n 's/^android[0-9]*-\([0-9]*\.[0-9]*\).*/\1/p'
}

# "android12-5.10-2025-12_r1" -> "android12"
get_android_major() {
    local kernel_tag="$1"
    echo "$kernel_tag" | sed -n 's/^\(android[0-9]*\).*/\1/p'
}

# "android12-5.10-2025-12_r1" -> "12"
get_android_version() {
    local kernel_tag="$1"
    echo "$kernel_tag" | sed -n 's/^android\([0-9]\+\).*/\1/p'
}

# --- Docker helpers ---

# Build a Docker image if it doesn't exist.
# Usage: _ensure_image <image-name> <dockerfile>
_ensure_image() {
    local image="$1" dockerfile="$2"

    if docker image inspect "$image" >/dev/null 2>&1; then
        return 0
    fi

    log "Building Docker image: $image (from $dockerfile)"
    docker build \
        --build-arg USER_UID="$(id -u)" \
        --build-arg USER_GID="$(id -g)" \
        --build-arg USERNAME="${USER:-builder}" \
        -f "$BASE_DIR/build-env/$dockerfile" \
        -t "$image" \
        "$BASE_DIR/build-env"

    if [ $? -ne 0 ]; then
        log_indent "ERROR: Docker image build failed: $image"
        return 1
    fi
    log_indent "Docker image built successfully: $image"
}
