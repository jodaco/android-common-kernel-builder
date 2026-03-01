#!/usr/bin/env bash
# Manifest validation: check refs against local mirrors, fix deprecated refs.
# Requires: common.sh sourced first (for BASE_DIR, log, log_indent).
#
# Library usage:
#   source build-env/validate.sh
#   validate_manifest <manifest.xml> <mirror_dir> [--fix]
#
# Standalone usage:
#   ./build-env/validate.sh <manifest.xml> <mirror_dir> [--fix]

MANIFEST_CACHE_DIR="${BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/manifest-cache"
MANIFEST_CACHE_MAX_AGE_DAYS=7

# Colors for validation output (disabled if not a terminal)
if [[ -t 1 ]]; then
    _VM_RED=$'\e[31m' _VM_GREEN=$'\e[32m' _VM_YELLOW=$'\e[33m'
    _VM_BOLD=$'\e[1m' _VM_DIM=$'\e[2m' _VM_RST=$'\e[0m'
else
    _VM_RED='' _VM_GREEN='' _VM_YELLOW=''
    _VM_BOLD='' _VM_DIM='' _VM_RST=''
fi

# --- Internal helpers ---

_vm_cache_path() {
    local repo_name="$1"
    echo "$MANIFEST_CACHE_DIR/${repo_name//\//%}.refs"
}

_vm_cache_is_fresh() {
    local cache_file="$1"
    [[ -f "$cache_file" ]] || return 1
    local age_seconds
    age_seconds=$(( $(date +%s) - $(stat -c %Y "$cache_file") ))
    (( age_seconds < MANIFEST_CACHE_MAX_AGE_DAYS * 86400 ))
}

_vm_populate_cache() {
    local repo_name="$1"
    local mirror_dir="$2"
    local cache_file
    cache_file="$(_vm_cache_path "$repo_name")"

    if _vm_cache_is_fresh "$cache_file"; then
        return 0
    fi

    local mirror_bare="$mirror_dir/${repo_name}.git"
    if [[ -d "$mirror_bare" ]]; then
        log_indent "${_VM_DIM}cache: $repo_name (local mirror)${_VM_RST}"
        git ls-remote --heads --tags "$mirror_bare" 2>/dev/null > "$cache_file" || {
            log_indent "${_VM_YELLOW}warn: git ls-remote failed for local $mirror_bare${_VM_RST}"
            rm -f "$cache_file"
            return 1
        }
    else
        log_indent "${_VM_DIM}cache: $repo_name (network)${_VM_RST}"
        timeout 60 git ls-remote --heads --tags "https://android.googlesource.com/${repo_name}" \
            2>/dev/null > "$cache_file" || {
            log_indent "${_VM_YELLOW}warn: git ls-remote failed for remote $repo_name${_VM_RST}"
            rm -f "$cache_file"
            return 1
        }
    fi
    return 0
}

_vm_check_named_ref() {
    local repo_name="$1"
    local ref_name="$2"
    local cache_file
    cache_file="$(_vm_cache_path "$repo_name")"

    if [[ ! -f "$cache_file" ]]; then
        echo "uncached"
        return
    fi

    if grep -q "refs/heads/${ref_name}$" "$cache_file"; then
        echo "branch"
    elif grep -q "refs/tags/${ref_name}$" "$cache_file"; then
        echo "tag"
    elif grep -q "refs/heads/deprecated/${ref_name}$" "$cache_file"; then
        echo "deprecated-branch"
    elif grep -q "refs/tags/deprecated/${ref_name}$" "$cache_file"; then
        echo "deprecated-tag"
    else
        echo "missing"
    fi
}

_vm_check_sha() {
    local repo_name="$1"
    local sha="$2"
    local mirror_dir="$3"
    local mirror_bare="$mirror_dir/${repo_name}.git"

    if [[ ! -d "$mirror_bare" ]]; then
        echo "no-mirror"
        return
    fi

    if git -C "$mirror_bare" cat-file -e "$sha" 2>/dev/null; then
        echo "exists"
    else
        echo "missing"
    fi
}

_vm_is_sha() {
    local val="$1"
    [[ ${#val} -eq 40 && "$val" =~ ^[0-9a-f]+$ ]]
}

# --- Main validation function ---

# validate_manifest <manifest_xml> <mirror_dir> [--fix]
#
# Validates refs in a repo manifest XML against a local mirror.
# With --fix, rewrites deprecated refs in the manifest in-place.
#
# Returns: 0 if all refs OK (or fixed), 1 if missing refs found.
validate_manifest() {
    local manifest_xml="$1"
    local mirror_dir="$2"
    local fix_mode=0
    [[ "${3:-}" == "--fix" ]] && fix_mode=1

    [[ -f "$manifest_xml" ]] || { log_indent "ERROR: manifest not found: $manifest_xml"; return 1; }
    [[ -d "$mirror_dir" ]] || { log_indent "ERROR: mirror dir not found: $mirror_dir"; return 1; }

    manifest_xml="$(cd "$(dirname "$manifest_xml")" && pwd)/$(basename "$manifest_xml")"
    mirror_dir="$(cd "$mirror_dir" && pwd)"

    mkdir -p "$MANIFEST_CACHE_DIR"

    # Parse manifest XML → tab-separated: name, path, revision, upstream, dest-branch
    local parsed
    parsed=$(python3 -c "
import xml.etree.ElementTree as ET, sys
tree = ET.parse(sys.argv[1])
root = tree.getroot()
d = root.find('default')
dr = d.get('revision','') if d is not None else ''
du = d.get('upstream','') if d is not None else ''
dd = d.get('dest-branch','') if d is not None else ''
print(f'__default__\t__default__\t{dr}\t{du}\t{dd}')
for p in root.findall('project'):
    print(f'{p.get(\"name\",\"\")}\t{p.get(\"path\",p.get(\"name\",\"\"))}\t{p.get(\"revision\",dr)}\t{p.get(\"upstream\",\"\")}\t{p.get(\"dest-branch\",\"\")}')
" "$manifest_xml") || { log_indent "ERROR: failed to parse manifest XML"; return 1; }

    # Collect unique repo names (skip __default__)
    local repo_names
    mapfile -t repo_names < <(echo "$parsed" | tail -n +2 | cut -f1 | sort -u)

    log_indent "Validating manifest (${#repo_names[@]} repos)..."

    # Build/refresh ref cache
    local cache_failures=()
    for repo in "${repo_names[@]}"; do
        _vm_populate_cache "$repo" "$mirror_dir" || cache_failures+=("$repo")
    done

    # Validate each ref
    local total=0 ok=0 deprecated=0 missing=0 unchecked=0
    local deprecated_fixes=()

    _vm_validate_ref() {
        local repo_name="$1" attr_name="$2" ref_value="$3"
        [[ -z "$ref_value" ]] && return 0

        if _vm_is_sha "$ref_value"; then
            local sha_status
            sha_status=$(_vm_check_sha "$repo_name" "$ref_value" "$mirror_dir")
            case "$sha_status" in
                exists)     ok=$((ok + 1)) ;;
                missing)    missing=$((missing + 1))
                            log_indent "  ${_VM_RED}MISSING${_VM_RST} $repo_name $attr_name ${ref_value:0:12}..." ;;
                no-mirror)  unchecked=$((unchecked + 1)) ;;
            esac
        else
            local ref_status
            ref_status=$(_vm_check_named_ref "$repo_name" "$ref_value")
            case "$ref_status" in
                branch|tag)
                    ok=$((ok + 1)) ;;
                deprecated-branch|deprecated-tag)
                    deprecated=$((deprecated + 1))
                    deprecated_fixes+=("${repo_name}|${attr_name}|${ref_value}|deprecated/${ref_value}")
                    log_indent "  ${_VM_YELLOW}DEPRECATED${_VM_RST} $repo_name $attr_name $ref_value → deprecated/$ref_value" ;;
                missing)
                    missing=$((missing + 1))
                    log_indent "  ${_VM_RED}MISSING${_VM_RST} $repo_name $attr_name $ref_value" ;;
                uncached)
                    unchecked=$((unchecked + 1)) ;;
            esac
        fi
        total=$((total + 1))
    }

    while IFS=$'\t' read -r proj_name proj_path proj_rev proj_upstream proj_destbranch; do
        [[ "$proj_name" == "__default__" ]] && continue
        _vm_validate_ref "$proj_name" "revision" "$proj_rev"
        [[ -n "$proj_upstream" ]] && _vm_validate_ref "$proj_name" "upstream" "$proj_upstream"
        [[ -n "$proj_destbranch" ]] && _vm_validate_ref "$proj_name" "dest-branch" "$proj_destbranch"
    done <<< "$parsed"

    log_indent "Refs: $ok OK, $deprecated deprecated, $missing missing, $unchecked unchecked (of $total)"

    if [[ ${#cache_failures[@]} -gt 0 ]]; then
        log_indent "${_VM_YELLOW}Cache failures: ${cache_failures[*]}${_VM_RST}"
    fi

    # Fix deprecated refs in-place
    if [[ $deprecated -gt 0 && $fix_mode -eq 1 ]]; then
        log_indent "Fixing $deprecated deprecated ref(s) in manifest..."
        python3 -c "
import xml.etree.ElementTree as ET, sys
manifest_path = sys.argv[1]
fixes = [tuple(a.split('|')) for a in sys.argv[2:]]
tree = ET.parse(manifest_path)
root = tree.getroot()
changes = 0
for proj in root.findall('project'):
    name = proj.get('name', '')
    for repo, attr, old_ref, new_ref in fixes:
        if name == repo and proj.get(attr, '') == old_ref:
            proj.set(attr, new_ref)
            changes += 1
ET.indent(tree, space='  ')
tree.write(manifest_path, encoding='unicode', xml_declaration=True)
# Ensure trailing newline
with open(manifest_path, 'a') as f:
    f.write('\n')
print(changes)
" "$manifest_xml" "${deprecated_fixes[@]}"
        log_indent "Fixed deprecated refs in manifest."
    elif [[ $deprecated -gt 0 ]]; then
        log_indent "${_VM_YELLOW}$deprecated deprecated ref(s) found. Use --fix to rewrite.${_VM_RST}"
    fi

    if [[ $missing -gt 0 ]]; then
        log_indent "${_VM_RED}$missing ref(s) missing — manifest validation failed.${_VM_RST}"
        return 1
    fi

    return 0
}

# --- Standalone CLI ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail

    # Provide log/log_indent if not already sourced from common.sh
    if ! declare -f log >/dev/null 2>&1; then
        log() { echo "=== $* ==="; }
        log_indent() { echo "  $*"; }
    fi

    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <manifest.xml> <mirror_dir> [--fix]"
        echo
        echo "  manifest.xml   Path to repo manifest XML file"
        echo "  mirror_dir     Path to local repo mirror"
        echo "  --fix          Fix deprecated refs in-place"
        exit 1
    fi

    validate_manifest "$@"
fi
