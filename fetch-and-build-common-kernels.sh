#!/usr/bin/env bash
set -euo pipefail

# Android versions to process (space-separated).
# Only tags matching these prefixes will be fetched/built/tested.
TARGETS="android15 android16"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/build-env/common.sh"
source "$SCRIPT_DIR/build-env/mirrors.sh"
source "$SCRIPT_DIR/build-env/validate.sh"
source "$SCRIPT_DIR/build-env/fetch.sh"
source "$SCRIPT_DIR/build-env/cuttlefish.sh"
source "$SCRIPT_DIR/build-env/artifacts.sh"
source "$SCRIPT_DIR/build-env/build.sh"

cleanup() {
    trap - INT TERM  # prevent re-entry
    echo ""
    echo "Interrupted."
    pkill -P $$ 2>/dev/null || true
    kill 0 2>/dev/null || true
    exit 130
}
trap cleanup INT TERM

SKIP_CF=false
DISABLE_CLEANUP=false
FETCH_ONLY=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --init-mirrors      Initialize/refresh all repo mirrors"
    echo "  --tag TAG           Process only the specified kernel tag"
    echo "  --all               Process all rows in the CSV"
    echo "  --skip-cf           Skip cuttlefish boot test, collect artifacts directly"
    echo "  --disable-cleanup   Leave checkout directories in place after build"
    echo "  --fetch-only        Fetch only (no build/test), leaves checkout in place"
    echo ""
    echo "Without --tag or --all, processes only the last CSV row (test mode)."
}

process_row() {
    local raw_line="$1"
    local force="${2:-false}"

    IFS=',' read -r kernel_tag commit git_url manifest1 manifest2 <<< "$raw_line"

    if [ -z "$manifest1" ]; then
        log "Skipping $kernel_tag: no manifest1 value"
        record_result "$raw_line" "no" "no" "no"
        return
    fi

    if [ "$force" = false ]; then
        # Skip if this exact tag already exists in build-output
        if [ -f "$BUILD_OUTPUT_DIR/${kernel_tag}.zip" ]; then
            log "Skipping $kernel_tag: already built (${kernel_tag}.zip)"
            return
        fi

        # Skip if we already have a build for the same YYYY-MM period
        # e.g. android12-5.10-2025-09_r1 -> date prefix android12-5.10-2025-09
        local date_prefix="${kernel_tag%_r*}"
        local existing_zip
        existing_zip=$(ls "$BUILD_OUTPUT_DIR/${date_prefix}"_r*.zip 2>/dev/null | head -1) || true
        if [ -n "$existing_zip" ]; then
            log "Skipping $kernel_tag: already built ($(basename "$existing_zip"))"
            return
        fi
    else
        log "Force rebuild: $kernel_tag"
    fi

    local fetch_result="no"
    local build_result="no"
    local boot_result="no"

    # 1. Fetch
    if fetch_kernel "$kernel_tag" "$manifest1"; then
        fetch_result="yes"

        if [ "$FETCH_ONLY" = true ]; then
            log_indent "Fetch-only mode: checkout ready at $BASE_DIR/$kernel_tag"
        else
            # 2. Build (patch + compile in Docker)
            if build_kernel "$kernel_tag"; then
                build_result="yes"

                if [ "$SKIP_CF" = true ]; then
                    # Skip cuttlefish, collect artifacts with -not-tested-in-cf suffix
                    boot_result="skipped"
                    collect_artifacts "$kernel_tag" "${kernel_tag}-not-tested-in-cf"
                else
                    # 3. Boot test in cuttlefish
                    if boot_test "$kernel_tag"; then
                        boot_result="yes"

                        # 4. Collect artifacts, zip, and remove checkout
                        collect_artifacts "$kernel_tag"
                    fi
                fi
            fi
        fi
    else
        log_indent "Fetch failed, skipping build."
    fi

    # Clean up checkout dir if it still exists (e.g. build failed)
    if [ "$DISABLE_CLEANUP" = true ]; then
        [ -d "$BASE_DIR/$kernel_tag" ] && log_indent "Keeping checkout: $kernel_tag/ (--disable-cleanup)"
    elif [ -d "$BASE_DIR/$kernel_tag" ]; then
        log_indent "Cleaning up checkout: $kernel_tag/"
        rm -rf "$BASE_DIR/$kernel_tag" || log_indent "WARNING: cleanup incomplete for $kernel_tag/"
    fi

    record_result "$raw_line" "$fetch_result" "$build_result" "$boot_result"
}

main() {
    local mode="test"  # default: last row only
    local target_tag=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --init-mirrors)
                init_mirrors
                exit $?
                ;;
            --tag)
                mode="tag"
                target_tag="${2:?ERROR: --tag requires a kernel tag argument}"
                shift
                ;;
            --all)
                mode="all"
                ;;
            --skip-cf)
                SKIP_CF=true
                ;;
            --disable-cleanup)
                DISABLE_CLEANUP=true
                ;;
            --fetch-only)
                FETCH_ONLY=true
                DISABLE_CLEANUP=true
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
        shift
    done

    ensure_mirrors
    if [ "$FETCH_ONLY" = false ]; then
        ensure_build_image
    fi
    init_results

    if [ "$mode" = "tag" ]; then
        # Find the row matching the target tag
        local matched_line
        matched_line=$(grep "^${target_tag}," "$CSV_FILE" || true)
        if [ -z "$matched_line" ]; then
            log "ERROR: Tag '$target_tag' not found in $CSV_FILE"
            exit 1
        fi
        log "Processing single tag: $target_tag"
        process_row "$matched_line" true
    else
        if [ "$mode" = "test" ]; then
            # Find the last CSV row matching TARGETS
            local last_match=""
            while IFS= read -r raw_line; do
                local row_tag="${raw_line%%,*}"
                is_target "$row_tag" && last_match="$raw_line"
            done < <(tail -n +2 "$CSV_FILE")

            if [ -z "$last_match" ]; then
                log "No rows match TARGETS ($TARGETS)"
                exit 1
            fi
            log "Test mode: processing last matching row"
            process_row "$last_match"
        else
            # --all: process every matching row
            while IFS= read -r raw_line; do
                local row_tag="${raw_line%%,*}"
                is_target "$row_tag" || continue
                process_row "$raw_line"
            done < <(tail -n +2 "$CSV_FILE")
        fi
    fi

    log "Done"
}

main "$@"
