#!/usr/bin/env bash
# Cuttlefish boot test in Docker.
# Requires: common.sh sourced first.

CF_DIR="$BASE_DIR/cf"
CF_RUNTIME_DIR="$BASE_DIR/.cf-runtime"
CUTTLEFISH_IMAGE="${CUTTLEFISH_IMAGE:-common-kernel-cuttlefish}"
BOOT_TIMEOUT=300  # seconds to wait for adb device
CVD_INSTANCE=10   # cuttlefish-host-resources creates TAP devices for instances 1-10
CVD_ADB_PORT=$((6520 + CVD_INSTANCE - 1))  # 6529

ensure_cuttlefish_image() {
    _ensure_image "$CUTTLEFISH_IMAGE" "Dockerfile.cuttlefish"
}

# Boot-test a built kernel in cuttlefish.
# Launches cuttlefish with our custom kernel, waits for adb, checks uname.
boot_test() {
    local kernel_tag="$1"
    local android_major dist_dir variant_dir runtime_dir
    local kernel_image initramfs_image

    android_major=$(get_android_major "$kernel_tag")
    local kernel_version
    kernel_version=$(get_kernel_version "$kernel_tag")
    local kv_short="${kernel_version/./}"   # "5.10" -> "510"

    # Check for version-specific cf subdir first (e.g., cf/android13/510/),
    # fall back to flat layout (e.g., cf/android12/).
    if [ -d "$CF_DIR/$android_major/$kv_short" ]; then
        variant_dir="$CF_DIR/$android_major/$kv_short"
    else
        variant_dir="$CF_DIR/$android_major"
    fi

    if [ ! -d "$variant_dir" ]; then
        log_indent "WARNING: No cuttlefish artifacts at $variant_dir, skipping boot test"
        return 1
    fi

    # Find build outputs
    dist_dir=$(find "$BASE_DIR/$kernel_tag/out" -maxdepth 2 -name dist -type d 2>/dev/null | head -1)
    if [ -z "$dist_dir" ]; then
        log_indent "ERROR: No dist/ directory found in build output"
        return 1
    fi

    kernel_image="$dist_dir/bzImage"
    initramfs_image="$dist_dir/initramfs.img"

    if [ ! -f "$kernel_image" ]; then
        log_indent "ERROR: No bzImage at $kernel_image"
        return 1
    fi
    if [ ! -f "$initramfs_image" ]; then
        log_indent "ERROR: No initramfs.img at $initramfs_image"
        return 1
    fi

    # Prepare runtime directory (per kernel version to avoid host package conflicts)
    if [ -d "$CF_DIR/$android_major/$kv_short" ]; then
        runtime_dir="$CF_RUNTIME_DIR/$android_major/$kv_short"
    else
        runtime_dir="$CF_RUNTIME_DIR/$android_major"
    fi
    mkdir -p "$runtime_dir"

    # Find artifact filenames
    local host_pkg image_zip
    host_pkg=$(find "$variant_dir" -maxdepth 1 -name 'cvd-host_package*.tar.gz' | head -1)
    image_zip=$(find "$variant_dir" -maxdepth 1 -name 'aosp_cf_x86_64*phone-img*.zip' | head -1)

    if [ -z "$host_pkg" ] || [ -z "$image_zip" ]; then
        log_indent "ERROR: Missing cuttlefish artifacts in $variant_dir"
        return 1
    fi

    local host_pkg_container="/cf/$(basename "$host_pkg")"
    local image_zip_container="/cf/$(basename "$image_zip")"

    ensure_cuttlefish_image || return 1

    log "Boot testing: $kernel_tag in cuttlefish (${variant_dir#$CF_DIR/})"
    log_indent "Kernel: $kernel_image"
    log_indent "Initramfs: $initramfs_image"
    log_indent "Runtime: $runtime_dir"
    log_indent "CF artifacts: $variant_dir"

    local container_name="cuttlefish-test-${kernel_tag//[^a-zA-Z0-9_-]/-}"

    # Remove stale container from a previous run
    if docker container inspect "$container_name" >/dev/null 2>&1; then
        log_indent "Removing stale container: $container_name"
        docker rm -f "$container_name" >/dev/null 2>&1 || true
    fi

    # Extract expected kernel version from vmlinux
    local expected_ver
    expected_ver=$(strings "$dist_dir/vmlinux" | grep -oP '^Linux version \K\S+' | head -1)
    if [ -z "$expected_ver" ]; then
        log_indent "WARNING: Could not extract version from vmlinux"
    else
        log_indent "Expected kernel: $expected_ver"
    fi

    docker run --rm \
        --name "$container_name" \
        --privileged \
        --device /dev/kvm \
        --ulimit nofile=65536:65536 \
        -v "$dist_dir:/dist" \
        -v "$variant_dir:/cf:ro" \
        -v "$runtime_dir:/runtime" \
        -v "$BASE_DIR/test-programs:/test-programs:ro" \
        "$CUTTLEFISH_IMAGE" \
        sh -c '
            set -eu
            cd /runtime
            # Start cuttlefish host networking (bridges, tap devices)
            sudo /etc/init.d/cuttlefish-host-resources start

            # Extract host package if not cached
            if [ ! -x ./bin/launch_cvd ]; then
                echo "Extracting host package..."
                tar -xf "'"$host_pkg_container"'"
            fi

            # Extract system images if not cached
            if ! ls ./*.img >/dev/null 2>&1; then
                echo "Extracting system images..."
                unzip -o "'"$image_zip_container"'"
            fi

            # Clear stale instance state from previous runs
            rm -rf ./cuttlefish/instances ./cuttlefish/assembly

            # Start adb server before launching cuttlefish
            adb start-server

            # Boot with our custom kernel in background
            echo "Launching cuttlefish with custom kernel..."
            HOME=/runtime ./bin/launch_cvd \
                -base_instance_num='"$CVD_INSTANCE"' \
                -kernel_path /dist/bzImage \
                -initramfs_path /dist/initramfs.img \
                -cpus 6 \
                -gpu_mode=guest_swiftshader \
                -enable_modem_simulator=false \
                -report_anonymous_usage_stats=n \
                -start_webrtc=true \
                -daemon &
            CVD_PID=$!
            sleep 5

            # Log paths (instance number from CVD_INSTANCE)
            CVD_LOG_DIR=/runtime/cuttlefish/instances/cvd-'"$CVD_INSTANCE"'
            CVD_LAUNCHER_LOG=$CVD_LOG_DIR/logs/launcher.log
            CVD_KERNEL_LOG=$CVD_LOG_DIR/kernel.log

            # Poll adb connect until device appears, cvd crashes, or timeout
            timeout='"$BOOT_TIMEOUT"'
            start_time=$(date +%s)
            connected=false
            echo "Waiting for adb device (timeout: ${timeout}s, cvd pid: $CVD_PID)..."
            while [ $(($(date +%s) - start_time)) -lt "$timeout" ]; do
                # Check if launch_cvd crashed
                if ! kill -0 $CVD_PID 2>/dev/null; then
                    echo "ERROR: launch_cvd (pid $CVD_PID) died"
                    break
                fi
                if adb connect 127.0.0.1:'"$CVD_ADB_PORT"' 2>&1 | grep -q "connected"; then
                    if adb -s 127.0.0.1:'"$CVD_ADB_PORT"' shell true 2>/dev/null; then
                        connected=true
                        break
                    fi
                fi
                elapsed=$(($(date +%s) - start_time))
                echo "  still waiting... (${elapsed}s elapsed)"
                sleep 5
            done

            if [ "$connected" = false ]; then
                echo "ERROR: adb device did not come up within ${timeout}s"
                echo "--- cuttlefish launcher.log ---"
                cat "$CVD_LAUNCHER_LOG" 2>/dev/null || echo "(no launcher.log)"
                echo "--- cuttlefish kernel.log (last 50 lines) ---"
                tail -50 "$CVD_KERNEL_LOG" 2>/dev/null || echo "(no kernel.log)"
                echo "--- adb devices ---"
                adb devices -l
                HOME=/runtime ./bin/stop_cvd || true
                exit 1
            fi

            ADB="adb -s 127.0.0.1:'"$CVD_ADB_PORT"'"
            LOG=/dist/test.log
            echo "Device online. Checking kernel..."

            # Try adb root for dmesg access; fall back to su
            USE_SU=false
            if $ADB root 2>&1 | grep -q "cannot run as root\|adbd not running as root"; then
                echo "adb root not available, will use su for privileged commands"
                USE_SU=true
            else
                sleep 2  # adb restarts after root
                $ADB wait-for-device
            fi

            # Helper: run a shell command with root if needed
            adb_shell() {
                if [ "$USE_SU" = true ]; then
                    $ADB shell "su -c '$*'" | tr -d "\r"
                else
                    $ADB shell "$@" | tr -d "\r"
                fi
            }

            # Kernel version
            adb_shell uname -r > /dist/uname-r.txt
            echo "=== uname -r ===" >> "$LOG"
            cat /dist/uname-r.txt >> "$LOG"
            echo "" >> "$LOG"
            echo "=== uname -a ===" >> "$LOG"
            adb_shell uname -a | tee -a "$LOG"
            echo "" >> "$LOG"

            # Verify kernel config has our required options
            echo "Checking kernel config (KASAN_GENERIC, KCOV)..."
            echo "=== kernel config check ===" >> "$LOG"
            adb_shell zcat /proc/config.gz > /dist/kernel-config.txt
            KCONFIG=$(grep -E "CONFIG_KASAN_GENERIC=y|CONFIG_KCOV=y" /dist/kernel-config.txt || true)
            echo "$KCONFIG" >> "$LOG"
            echo "$KCONFIG"
            KCONFIG_COUNT=$(echo "$KCONFIG" | grep -c "=y" || true)
            if [ "$KCONFIG_COUNT" -lt 2 ]; then
                echo "FAIL: Expected CONFIG_KASAN_GENERIC=y and CONFIG_KCOV=y but only found $KCONFIG_COUNT/2"
                echo "FAIL: kernel config missing required options" >> "$LOG"
                HOME=/runtime ./bin/stop_cvd || true
                exit 1
            fi
            echo "Kernel config verified: KASAN_GENERIC and KCOV enabled"
            echo "" >> "$LOG"

            # Push and run patch verification
            echo "Running patch verification (repro)..."
            $ADB push /test-programs/repro /data/local/tmp/repro
            $ADB shell chmod 755 /data/local/tmp/repro
            echo "=== repro output ===" >> "$LOG"
            adb_shell /data/local/tmp/repro | tee -a "$LOG"
            echo "" >> "$LOG"

            # Capture dmesg lines from our patches
            echo "Capturing patch trace from dmesg..."
            echo "=== patch trace (dmesg) ===" >> "$LOG"
            adb_shell dmesg \
                | grep -E "call_(void|int)_hook|avc_has_perm|capability" \
                | tee -a "$LOG"
            echo "" >> "$LOG"
            TRACE_LINES=$(grep -c -E "call_(void|int)_hook|avc_has_perm|capability" "$LOG" || true)
            echo "Patch trace: $TRACE_LINES lines captured"

            if [ "$TRACE_LINES" -eq 0 ]; then
                echo "WARNING: No patch trace output found in dmesg"
            fi

            # Stop cuttlefish
            echo "Stopping cuttlefish..."
            HOME=/runtime ./bin/stop_cvd || true

            echo "Boot test PASSED"
        ' 2>&1 | tee "/tmp/boot-test-${kernel_tag}.log"

    local exit_code=${PIPESTATUS[0]}
    if [ "$exit_code" -ne 0 ]; then
        log_indent "Boot test FAILED (exit code $exit_code)"
        docker rm -f "$container_name" 2>/dev/null || true
        return 1
    fi

    # Verify running kernel matches what we built
    if [ -f "$dist_dir/uname-r.txt" ] && [ -n "$expected_ver" ]; then
        local running_ver
        running_ver=$(cat "$dist_dir/uname-r.txt")
        if [ "$running_ver" = "$expected_ver" ]; then
            log_indent "Kernel version verified: $running_ver"
        else
            log_indent "WARNING: Kernel mismatch! running=$running_ver expected=$expected_ver"
            return 1
        fi
    fi

    log_indent "Boot test PASSED"
    return 0
}
