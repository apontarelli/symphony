#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#define _DARWIN_C_SOURCE

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define FRAME_SIZE 65536U
#define FRAME_HEADER_SIZE 4U
#define MAX_PAYLOAD_LENGTH (FRAME_SIZE - FRAME_HEADER_SIZE)

#if defined(NAME_MAX) && NAME_MAX < (FRAME_SIZE - FRAME_HEADER_SIZE - 1U)
#define MAX_NAME_LENGTH ((size_t)NAME_MAX)
#else
#define MAX_NAME_LENGTH (FRAME_SIZE - FRAME_HEADER_SIZE - 1U)
#endif

enum directory_state {
    DIRECTORY_NOT_OPEN = 0,
    DIRECTORY_OPEN,
    DIRECTORY_ENDED,
    DIRECTORY_FAILED
};

/* A single bounded output buffer is sufficient because requests are serialized. */
static unsigned char frame[FRAME_SIZE];

static int read_request(unsigned char *request)
{
    for (;;) {
        ssize_t count = read(STDIN_FILENO, request, 1);

        if (count == 1) {
            return 1;
        }
        if (count == 0) {
            return 0;
        }
        if (errno != EINTR) {
            return -1;
        }
    }
}

static int write_all(const unsigned char *buffer, size_t length)
{
    size_t offset = 0;

    while (offset < length) {
        ssize_t count = write(STDOUT_FILENO, buffer + offset, length - offset);

        if (count > 0) {
            offset += (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }

    return 0;
}

static int write_frame(size_t payload_length)
{
    if (payload_length > MAX_PAYLOAD_LENGTH || payload_length > UINT32_MAX) {
        return -1;
    }

    frame[0] = (unsigned char)((payload_length >> 24) & 0xffU);
    frame[1] = (unsigned char)((payload_length >> 16) & 0xffU);
    frame[2] = (unsigned char)((payload_length >> 8) & 0xffU);
    frame[3] = (unsigned char)(payload_length & 0xffU);

    return write_all(frame, sizeof(uint32_t) + payload_length);
}

static int write_tag(unsigned char tag)
{
    frame[sizeof(uint32_t)] = tag;
    return write_frame(1);
}

static int write_entry(const char *name)
{
    size_t name_length = strnlen(name, MAX_NAME_LENGTH + 1);

    if (name_length > MAX_NAME_LENGTH) {
        return -1;
    }

    frame[sizeof(uint32_t)] = 'D';
    memcpy(frame + sizeof(uint32_t) + 1, name, name_length);
    return write_frame(1 + name_length);
}

static int is_dot_entry(const char *name)
{
    return name[0] == '.' &&
           (name[1] == '\0' || (name[1] == '.' && name[2] == '\0'));
}

static void close_directory(DIR **directory)
{
    if (*directory != NULL) {
        (void)closedir(*directory);
        *directory = NULL;
    }
}

/* Inputs are canonical absolute paths. Walk from an anchored root descriptor so
 * a renamed ancestor cannot redirect enumeration through a replacement symlink. */
static DIR *open_directory(const char *path)
{
#if defined(O_SEARCH)
    const int search_flags = O_SEARCH;
#elif defined(O_PATH)
    const int search_flags = O_PATH;
#else
    const int search_flags = O_RDONLY;
#endif
    const int directory_flags = O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC;
    int descriptor = open("/", search_flags | directory_flags);
    const char *cursor = path + 1;
    char component[MAX_NAME_LENGTH + 1];

    if (descriptor < 0) {
        return NULL;
    }

    while (*cursor != '\0') {
        size_t length;
        int next;

        if (*cursor == '/') {
            cursor++;
            continue;
        }
        length = strcspn(cursor, "/");
        if (length > MAX_NAME_LENGTH) {
            close(descriptor);
            errno = ENAMETOOLONG;
            return NULL;
        }
        memcpy(component, cursor, length);
        component[length] = '\0';
        if (is_dot_entry(component)) {
            close(descriptor);
            errno = EINVAL;
            return NULL;
        }
        next = openat(descriptor, component, search_flags | directory_flags);
        close(descriptor);
        if (next < 0) {
            return NULL;
        }
        descriptor = next;
        cursor += length;
    }

    /* Search-only descriptors do not support readdir; reopen the anchored
     * directory itself for reading, without resolving its pathname again. */
    int readable = openat(descriptor, ".", O_RDONLY | directory_flags);
    close(descriptor);
    if (readable < 0) {
        return NULL;
    }
    DIR *directory = fdopendir(readable);
    if (directory == NULL) {
        close(readable);
    }
    return directory;
}

int main(int argc, char **argv)
{
    DIR *directory = NULL;
    enum directory_state state = DIRECTORY_NOT_OPEN;
    unsigned char request;

    /* Keep a broken consumer from terminating the helper before cleanup runs. */
    (void)signal(SIGPIPE, SIG_IGN);

    if (argc != 2 || argv[1] == NULL || argv[1][0] != '/') {
        return EXIT_FAILURE;
    }

    for (;;) {
        struct dirent *entry;
        int read_result = read_request(&request);

        if (read_result == 0 || (read_result == 1 && request == 'Q')) {
            close_directory(&directory);
            return EXIT_SUCCESS;
        }
        if (read_result < 0 || request != 'N') {
            close_directory(&directory);
            return EXIT_FAILURE;
        }

        if (state == DIRECTORY_NOT_OPEN) {
            directory = open_directory(argv[1]);
            if (directory == NULL) {
                state = DIRECTORY_FAILED;
                if (write_tag('F') < 0) {
                    close_directory(&directory);
                    return EXIT_FAILURE;
                }
                continue;
            }
            state = DIRECTORY_OPEN;
        }

        if (state == DIRECTORY_OPEN) {
            for (;;) {
                errno = 0;
                entry = readdir(directory);

                if (entry == NULL) {
                    if (errno == 0) {
                        state = DIRECTORY_ENDED;
                        close_directory(&directory);
                        if (write_tag('E') < 0) {
                            return EXIT_FAILURE;
                        }
                    } else {
                        state = DIRECTORY_FAILED;
                        close_directory(&directory);
                        if (write_tag('F') < 0) {
                            return EXIT_FAILURE;
                        }
                    }
                    break;
                }

                if (!is_dot_entry(entry->d_name)) {
                    if (write_entry(entry->d_name) < 0) {
                        close_directory(&directory);
                        return EXIT_FAILURE;
                    }
                    break;
                }
            }
        } else if (state == DIRECTORY_ENDED) {
            if (write_tag('E') < 0) {
                return EXIT_FAILURE;
            }
        } else {
            if (write_tag('F') < 0) {
                return EXIT_FAILURE;
            }
        }
    }
}
