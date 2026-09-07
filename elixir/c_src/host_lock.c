#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

/*
 * Write-free ownership probe.
 *
 * "probe <path>" opens the lock file without creating it and reports
 * whether the exclusive BEAM-held flock can be taken. A missing lock
 * file proves that no holder exists, and no path ever writes.
 */

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

#define EXIT_PROBE_FREE 0
#define EXIT_PROBE_HELD 2
#define EXIT_ERROR 3

static int open_lock_file(const char *path)
{
    int descriptor = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    struct stat status;

    if (descriptor < 0) {
        return -1;
    }
    if (fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_uid != geteuid() || (status.st_mode & 0777) != 0600 || status.st_nlink != 1) {
        close(descriptor);
        errno = EINVAL;
        return -1;
    }
    return descriptor;
}

static int take_exclusive_lock(int descriptor)
{
    while (flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EINTR) {
            continue;
        }
        return -1;
    }
    return 0;
}

static int run_probe(const char *path)
{
    int descriptor;

    descriptor = open_lock_file(path);
    if (descriptor < 0) {
        if (errno == ENOENT) {
            /* No lock file means no holder has ever claimed this root. */
            return EXIT_PROBE_FREE;
        }
        return EXIT_ERROR;
    }

    if (take_exclusive_lock(descriptor) != 0) {
        close(descriptor);
        if (errno == EWOULDBLOCK) {
            return EXIT_PROBE_HELD;
        }
        return EXIT_ERROR;
    }

    /* Free: release immediately without modifying the file. */
    while (flock(descriptor, LOCK_UN) != 0) {
        if (errno != EINTR) {
            close(descriptor);
            return EXIT_ERROR;
        }
    }

    close(descriptor);
    return EXIT_PROBE_FREE;
}

/* Start a new session with no terminal descriptors or parent ownership.
 * The intermediate child is reaped here; the grandchild belongs to init.
 */
static int detach(char **argv)
{
    int status;
    pid_t child = fork();
    if (child < 0) return EXIT_ERROR;
    if (child > 0) {
        while (waitpid(child, &status, 0) < 0) {
            if (errno != EINTR) return EXIT_ERROR;
        }
        return WIFEXITED(status) ? WEXITSTATUS(status) : EXIT_ERROR;
    }

    if (setsid() < 0) _exit(EXIT_ERROR);
    child = fork();
    if (child < 0) _exit(EXIT_ERROR);
    if (child > 0) _exit(0);

    umask(0077);
    int input = open("/dev/null", O_RDONLY);
    int output = open(argv[2], O_WRONLY | O_APPEND | O_NOFOLLOW);
    struct stat log_stat;
    if (input < 0 || output < 0 || fstat(output, &log_stat) != 0 ||
        !S_ISREG(log_stat.st_mode) || log_stat.st_uid != geteuid() ||
        (log_stat.st_mode & 0777) != 0600 || log_stat.st_nlink != 1) _exit(EXIT_ERROR);
    if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0 ||
        dup2(output, STDERR_FILENO) < 0) _exit(EXIT_ERROR);
    if (input > STDERR_FILENO) close(input);
    if (output > STDERR_FILENO) close(output);
    execvp(argv[3], &argv[3]);
    _exit(127);
}

int main(int argc, char **argv)
{
    if (argc == 3 && strcmp(argv[1], "probe") == 0) {
        return run_probe(argv[2]);
    }
    if (argc >= 4 && strcmp(argv[1], "detach") == 0) {
        return detach(argv);
    }
    return EXIT_ERROR;
}
