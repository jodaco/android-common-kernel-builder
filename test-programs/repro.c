/*
 * repro.c — Kernel patch verification program
 *
 * Exercises LSM hooks, capability checks, and SELinux AVC paths
 * that our syzbot2ftrace patches instrument with printk debug logging.
 *
 * The patches trigger on strcmp(current->comm, "repro") == 0, so this
 * binary MUST be named "repro" (or call prctl to set its comm).
 *
 * After running on a patched kernel, check dmesg for:
 *   - "call_void_hook calling ..."
 *   - "call_int_hook (lsm ...): calling ..."
 *   - "(capability ...)"
 *   - "avc_has_perm(): source=..., target=..."
 *
 * Build:
 *   x86_64-linux-android31-clang -static -o repro repro.c
 *
 * Usage on device:
 *   adb push repro /data/local/tmp/
 *   adb shell chmod 755 /data/local/tmp/repro
 *   adb shell /data/local/tmp/repro
 *   adb shell dmesg | grep -E 'call_(void|int)_hook|avc_has_perm|capability'
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/stat.h>

/* Read our own comm to verify it's set correctly */
static int verify_comm(void) {
    char comm[64] = {0};
    int fd = open("/proc/self/comm", O_RDONLY);
    if (fd < 0) {
        perror("open /proc/self/comm");
        return -1;
    }
    ssize_t n = read(fd, comm, sizeof(comm) - 1);
    close(fd);
    if (n <= 0) return -1;
    /* strip trailing newline */
    if (n > 0 && comm[n - 1] == '\n') comm[n - 1] = '\0';

    if (strcmp(comm, "repro") != 0) {
        fprintf(stderr, "ERROR: comm is '%s', expected 'repro'\n", comm);
        return -1;
    }
    printf("[OK] comm = '%s'\n", comm);
    return 0;
}

/*
 * Exercise 1: File operations
 * Triggers: security_file_open, security_inode_permission
 * -> call_int_hook file_open, inode_permission
 */
static void test_file_ops(void) {
    int fd;

    printf("\n--- File operations ---\n");

    /* Open a world-readable file */
    fd = open("/proc/version", O_RDONLY);
    if (fd >= 0) {
        char buf[256];
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = '\0';
            printf("[OK] read /proc/version: %.60s...\n", buf);
        }
        close(fd);
    } else {
        printf("[--] open /proc/version: %s\n", strerror(errno));
    }

    /* Try to open something we shouldn't be able to */
    fd = open("/proc/1/mem", O_RDONLY);
    if (fd >= 0) {
        printf("[OK] open /proc/1/mem succeeded (unexpected)\n");
        close(fd);
    } else {
        printf("[OK] open /proc/1/mem denied: %s (expected)\n", strerror(errno));
    }
}

/*
 * Exercise 2: Socket creation
 * Triggers: security_socket_create
 * -> call_int_hook socket_create
 */
static void test_socket(void) {
    int fd;

    printf("\n--- Socket operations ---\n");

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd >= 0) {
        printf("[OK] created TCP socket (fd=%d)\n", fd);
        close(fd);
    } else {
        printf("[--] socket(AF_INET, SOCK_STREAM): %s\n", strerror(errno));
    }

    /* Raw socket — likely denied, triggers capable(CAP_NET_RAW) */
    fd = socket(AF_INET, SOCK_RAW, 0);
    if (fd >= 0) {
        printf("[OK] created raw socket (fd=%d)\n", fd);
        close(fd);
    } else {
        printf("[OK] raw socket denied: %s (triggers capability check)\n", strerror(errno));
    }
}

/*
 * Exercise 3: Capability checks
 * Triggers: security_capable -> call_int_hook capable
 * The patch also prints "(capability N)" for each check.
 */
static void test_capabilities(void) {
    printf("\n--- Capability checks ---\n");

    /* Try setuid — triggers capable(CAP_SETUID) */
    if (setuid(0) == 0) {
        printf("[OK] setuid(0) succeeded (running as root)\n");
    } else {
        printf("[OK] setuid(0) denied: %s (triggers CAP_SETUID check)\n", strerror(errno));
    }

    /* Try chown — triggers capable(CAP_CHOWN) */
    if (chown("/data/local/tmp/repro", 0, 0) == 0) {
        printf("[OK] chown succeeded\n");
    } else {
        printf("[OK] chown denied: %s (triggers CAP_CHOWN check)\n", strerror(errno));
    }

    /* Try to set nice to -20 — triggers capable(CAP_SYS_NICE) */
    if (nice(-20) != -1 || errno != EPERM) {
        printf("[OK] nice(-20) succeeded or unexpected error\n");
    } else {
        printf("[OK] nice(-20) denied: %s (triggers CAP_SYS_NICE check)\n", strerror(errno));
    }
}

/*
 * Exercise 4: SELinux context reads
 * Triggers: avc_has_perm via /proc/self/attr/current access
 */
static void test_selinux(void) {
    int fd;
    char ctx[256] = {0};

    printf("\n--- SELinux operations ---\n");

    /* Read our own SELinux context */
    fd = open("/proc/self/attr/current", O_RDONLY);
    if (fd >= 0) {
        ssize_t n = read(fd, ctx, sizeof(ctx) - 1);
        if (n > 0) {
            ctx[n] = '\0';
            printf("[OK] SELinux context: %s\n", ctx);
        }
        close(fd);
    } else {
        printf("[--] open /proc/self/attr/current: %s\n", strerror(errno));
    }

    /* Try to access a protected path — triggers AVC check */
    fd = open("/sys/fs/selinux/enforce", O_RDONLY);
    if (fd >= 0) {
        char val[8] = {0};
        read(fd, val, sizeof(val) - 1);
        printf("[OK] SELinux enforce = %s\n", val);
        close(fd);
    } else {
        printf("[OK] /sys/fs/selinux/enforce: %s (triggers AVC)\n", strerror(errno));
    }

    /* Try to write SELinux context — should be denied */
    fd = open("/proc/self/attr/current", O_WRONLY);
    if (fd >= 0) {
        const char *new_ctx = "u:r:shell:s0";
        if (write(fd, new_ctx, strlen(new_ctx)) < 0) {
            printf("[OK] write SELinux context denied: %s (triggers AVC)\n", strerror(errno));
        }
        close(fd);
    } else {
        printf("[OK] open attr/current for write: %s (triggers AVC)\n", strerror(errno));
    }
}

/*
 * Exercise 5: /data and /system access
 * Broader SELinux + DAC checks
 */
static void test_filesystem_access(void) {
    int fd;

    printf("\n--- Filesystem access ---\n");

    /* Try accessing /system — triggers inode_permission + AVC */
    fd = open("/system/build.prop", O_RDONLY);
    if (fd >= 0) {
        printf("[OK] opened /system/build.prop\n");
        close(fd);
    } else {
        printf("[OK] /system/build.prop: %s (triggers security hooks)\n", strerror(errno));
    }

    /* Try creating a file in /data — triggers multiple hooks */
    fd = open("/data/repro_test", O_WRONLY | O_CREAT, 0644);
    if (fd >= 0) {
        printf("[OK] created /data/repro_test\n");
        unlink("/data/repro_test");
        close(fd);
    } else {
        printf("[OK] create /data/repro_test denied: %s (triggers security hooks)\n", strerror(errno));
    }
}

int main(void) {
    printf("=== syzbot2ftrace patch verification ===\n");
    printf("PID: %d\n", getpid());

    /* Set comm to "repro" — this activates the kernel patch hooks */
    if (prctl(PR_SET_NAME, "repro", 0, 0, 0) != 0) {
        perror("prctl(PR_SET_NAME)");
        return 1;
    }

    if (verify_comm() != 0) {
        return 1;
    }

    printf("\nRunning tests to trigger patched kernel hooks...\n");
    printf("Check 'dmesg' after this for patch output.\n");

    test_file_ops();
    test_socket();
    test_capabilities();
    test_selinux();
    test_filesystem_access();

    printf("\n=== Done. Run 'dmesg | grep -E \"call_(void|int)_hook|avc_has_perm|capability\"' to verify patches. ===\n");
    return 0;
}
