#define _POSIX_C_SOURCE 200809L
#define _DARWIN_C_SOURCE

#include "erl_nif.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>

/*
 * BEAM-held host ownership lock.
 *
 * The exclusive flock lives on a file descriptor owned by the BEAM
 * process itself and kept alive through a NIF resource, so the kernel
 * releases ownership exactly when the BEAM exits. There is no helper
 * process to kill, and no window in which a crashed or restarted owner
 * lets a second host acquire the lock while the first one is still
 * running.
 *
 * "acquire(path)" returns the resource holding the descriptor. The
 * caller keeps a persistent_term reference to the resource so the
 * descriptor outlives any single process inside the BEAM.
 */

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0
#endif

#ifndef O_CLOEXEC
#define O_CLOEXEC 0
#endif

typedef struct {
    int fd;
} symphony_host_lock;

static ErlNifResourceType *host_lock_resource_type;

static void host_lock_dtor(ErlNifEnv *env, void *resource)
{
    symphony_host_lock *lock = (symphony_host_lock *)resource;

    (void)env;
    if (lock->fd >= 0) {
        close(lock->fd);
        lock->fd = -1;
    }
}

static int upgrade(ErlNifEnv *env, void **priv_data, void **old_priv_data, ERL_NIF_TERM load_info)
{
    (void)env;
    (void)priv_data;
    (void)old_priv_data;
    (void)load_info;
    return 0;
}

static void unload(ErlNifEnv *env, void *priv_data)
{
    (void)env;
    (void)priv_data;
}

static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    int flags = ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER;

    (void)priv_data;
    (void)load_info;
    host_lock_resource_type =
        enif_open_resource_type(env, NULL, "symphony_host_lock", host_lock_dtor, flags, NULL);

    if (host_lock_resource_type == NULL) {
        return -1;
    }
    return 0;
}

static ERL_NIF_TERM make_atom(ErlNifEnv *env, const char *name)
{
    ERL_NIF_TERM atom;

    if (enif_make_existing_atom(env, name, &atom, ERL_NIF_LATIN1)) {
        return atom;
    }
    return enif_make_atom(env, name);
}

static ERL_NIF_TERM make_error(ErlNifEnv *env, const char *reason)
{
    return enif_make_tuple2(env, make_atom(env, "error"), make_atom(env, reason));
}

static int path_to_cstring(ErlNifEnv *env, ERL_NIF_TERM term, char *buffer, size_t capacity)
{
    ErlNifBinary binary;

    if (enif_inspect_iolist_as_binary(env, term, &binary) && binary.size > 0 &&
        binary.size < capacity && memchr(binary.data, '\0', binary.size) == NULL) {
        memcpy(buffer, binary.data, binary.size);
        buffer[binary.size] = '\0';
        return 1;
    }
    return 0;
}

static ERL_NIF_TERM acquire(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    char path[PATH_MAX];
    symphony_host_lock *lock;
    ERL_NIF_TERM resource;
    struct stat status;
    int fd;

    if (argc != 1) {
        return enif_make_badarg(env);
    }
    if (!path_to_cstring(env, argv[0], path, sizeof(path))) {
        return enif_make_badarg(env);
    }

    fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR);
    if (fd < 0) {
        return make_error(env, "open_failed");
    }

    if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_uid != geteuid() || (status.st_mode & 0777) != 0600 || status.st_nlink != 1) {
        close(fd);
        return make_error(env, "invalid_lock_file");
    }

    while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK) {
            close(fd);
            return make_error(env, "held");
        }
        if (errno != EINTR) {
            close(fd);
            return make_error(env, "flock_failed");
        }
    }

    lock = enif_alloc_resource(host_lock_resource_type, sizeof(symphony_host_lock));
    if (lock == NULL) {
        close(fd);
        return make_error(env, "resource_failed");
    }

    lock->fd = fd;
    resource = enif_make_resource(env, lock);
    enif_release_resource(lock);

    return enif_make_tuple2(env, make_atom(env, "ok"), resource);
}

static ErlNifFunc nif_functions[] = {
    {"acquire", 1, acquire, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(Elixir.SymphonyElixir.LocalHost.Lock, nif_functions, load, NULL, upgrade, unload)

