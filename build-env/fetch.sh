#!/usr/bin/env bash
# Fetch (repo init + repo sync) for individual kernel tags.
# Requires: common.sh sourced first.

fetch_kernel() {
    local kernel_tag="$1"
    local manifest_branch="$2"
    local tag_dir="$BASE_DIR/$kernel_tag"
    local rc=0

    log "Fetching: $kernel_tag (branch: $manifest_branch, reference: $MIRRORS_DIR)"

    # Always start fresh so repo init creates alternates from --reference
    rm -rf "$tag_dir" || true
    mkdir -p "$tag_dir"
    cd "$tag_dir"

    # repo init — use local mirror manifest to avoid network dependency
    local manifest_url="https://android.googlesource.com/kernel/manifest"
    if [ -d "$MIRRORS_DIR/kernel/manifest.git" ]; then
        manifest_url="$MIRRORS_DIR/kernel/manifest.git"
    fi
    log_indent "repo init (branch: $manifest_branch, manifest: $manifest_url)..."
    (yes 2>/dev/null || true) | timeout 300 repo init \
        -u "$manifest_url" \
        -b "$manifest_branch" \
        --reference="$MIRRORS_DIR" || rc=$?
    if [ "$rc" -ne 0 ]; then
        log_indent "repo init failed (exit $rc). Skipping $kernel_tag."
        rm -rf "$tag_dir" || true
        return 1
    fi

    # Validate manifest refs against mirror before syncing
    if ! validate_manifest "$tag_dir/.repo/manifests/default.xml" "$MIRRORS_DIR" --fix; then
        log_indent "Manifest validation failed. Skipping $kernel_tag."
        rm -rf "$tag_dir" || true
        return 1
    fi

    # repo sync
    log_indent "repo sync started at $(date '+%Y-%m-%d %H:%M:%S')..."
    rc=0
    timeout $((15 * 60)) repo sync -c --no-tags --no-clone-bundle --fail-fast || rc=$?
    if [ "$rc" -ne 0 ]; then
        log_indent "repo sync failed (exit $rc) at $(date '+%Y-%m-%d %H:%M:%S')"
        rm -rf "$tag_dir" || true
        return 1
    fi
    log_indent "repo sync succeeded at $(date '+%Y-%m-%d %H:%M:%S')"

    return 0
}
