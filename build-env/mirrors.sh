#!/usr/bin/env bash
# Mirror management.
# Requires: common.sh sourced first.
#
# Uses a single unified mirror at $MIRRORS_DIR initialized from
# common-android-mainline. This branch's manifest is a superset that
# contains all kernel projects, so it works as --reference for any
# manifest branch (android12-5.10, android14-6.1, etc.).

MIRROR_MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
MIRROR_MANIFEST_BRANCH="common-android-mainline"
MIRROR_SYNC_TIMEOUT=$((60 * 60))  # 60 minutes
MIRROR_SYNC_RETRIES=3

init_mirrors() {
    log "Initializing unified mirror at $MIRRORS_DIR (branch: $MIRROR_MANIFEST_BRANCH)"
    mkdir -p "$MIRRORS_DIR"
    cd "$MIRRORS_DIR"

    if [ ! -d "$MIRRORS_DIR/.repo" ]; then
        log_indent "repo init --mirror (branch: $MIRROR_MANIFEST_BRANCH)..."
        local rc=0
        (yes 2>/dev/null || true) | timeout 300 repo init \
            --mirror \
            -u "$MIRROR_MANIFEST_URL" \
            -b "$MIRROR_MANIFEST_BRANCH" || rc=$?
        if [ "$rc" -ne 0 ]; then
            log_indent "repo init --mirror failed (exit $rc)"
            return 1
        fi
    else
        log_indent "Mirror already initialized, will sync to refresh."
    fi

    local attempt
    for attempt in $(seq 1 "$MIRROR_SYNC_RETRIES"); do
        log_indent "repo sync attempt $attempt/$MIRROR_SYNC_RETRIES (timeout: ${MIRROR_SYNC_TIMEOUT}s)..."
        local rc=0
        timeout "$MIRROR_SYNC_TIMEOUT" repo sync || rc=$?
        if [ "$rc" -eq 0 ]; then
            log_indent "Mirror sync succeeded."
            return 0
        fi
        log_indent "repo sync failed (exit $rc) on attempt $attempt/$MIRROR_SYNC_RETRIES"
    done

    log "FATAL: Mirror sync failed after $MIRROR_SYNC_RETRIES attempts."
    return 1
}

# Check that the unified mirror exists.
ensure_mirrors() {
    if [ ! -d "$MIRRORS_DIR/.repo" ]; then
        log "FATAL: Mirror not found at $MIRRORS_DIR"
        log "Set up with: cd $MIRRORS_DIR && repo init --mirror -u https://android.googlesource.com/kernel/manifest -b common-android-mainline && repo sync"
        exit 1
    fi
}
