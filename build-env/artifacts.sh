#!/usr/bin/env bash
# Collect, package, and clean up build artifacts.
# Requires: common.sh sourced first.

BUILD_OUTPUT_DIR="$BASE_DIR/build-output"

# Rename build output, zip it, move zip to build-output/, then
# delete the full checkout directory to reclaim disk space.
collect_artifacts() {
    local kernel_tag="$1"
    local output_name="${2:-$kernel_tag}"
    local tag_dir="$BASE_DIR/$kernel_tag"
    local out_dir="$tag_dir/out"

    # Find the dist directory inside out/
    local dist_dir
    dist_dir=$(find "$out_dir" -maxdepth 2 -name dist -type d 2>/dev/null | head -1)

    if [ -z "$dist_dir" ]; then
        log_indent "ERROR: No dist/ directory found in $out_dir"
        return 1
    fi

    mkdir -p "$BUILD_OUTPUT_DIR"

    # Move dist to output name (inside tag_dir for zipping)
    log_indent "Collecting dist/ -> $output_name/"
    mv "$dist_dir" "$tag_dir/$output_name"

    # Zip it
    log_indent "Creating ${output_name}.zip..."
    (cd "$tag_dir" && zip -qr "${output_name}.zip" "$output_name")

    # Move zip to build-output/
    mv "$tag_dir/${output_name}.zip" "$BUILD_OUTPUT_DIR/"
    log_indent "Artifacts: $BUILD_OUTPUT_DIR/${output_name}.zip"

    # Remove the full checkout directory (unless --disable-cleanup)
    if [ "${DISABLE_CLEANUP:-false}" = true ]; then
        log_indent "Keeping checkout: $tag_dir/ (--disable-cleanup)"
    else
        log_indent "Removing checkout: $tag_dir/"
        rm -rf "$tag_dir" || true
    fi

    return 0
}
