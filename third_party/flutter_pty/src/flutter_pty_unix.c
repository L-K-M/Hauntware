
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <pthread.h>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

#include "forkpty.h"
#include "flutter_pty.h"

#include "include/dart_api.h"
#include "include/dart_api_dl.h"
#include "include/dart_native_api.h"

typedef struct PtyHandle
{
    int ptm;

    int pid;

    pthread_mutex_t mutex;

    bool ackRead;

    /* Séance: lifecycle bookkeeping — the two worker threads are kept so
       pty_close can join them (an exited joinable thread still holds its
       stack until joined), and `closed` makes pty_close idempotent. */
    pthread_t reader;

    pthread_t waiter;

    int reader_started;

    int waiter_started;

    int closed;

} PtyHandle;

typedef struct ReadLoopOptions
{
    int fd;

    pthread_mutex_t *mutex;

    Dart_Port port;

    bool waitForReadAck;

} ReadLoopOptions;

char *error_message = NULL;

static void *read_loop(void *arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;

    char buffer[1024];

    /* Séance: pty_close cancels this thread, which unwinds past the
       function's end — a tail free() would only run on the normal path.
       The cleanup handler fires on either exit, exactly once. */
    pthread_cleanup_push(free, options);

    while (1)
    {
        if (options->waitForReadAck)
        {
            // if we are in ack mode then we get a mutex here that is
            // freed again once the chunk of data has been processed
            pthread_mutex_lock(options->mutex);
        }
        ssize_t n = read(options->fd, buffer, sizeof(buffer));

        if (n < 0)
        {
            // TODO: handle error
            break;
        }

        if (n == 0)
        {
            break;
        }

        Dart_CObject result;
        result.type = Dart_CObject_kTypedData;
        result.value.as_typed_data.type = Dart_TypedData_kUint8;
        result.value.as_typed_data.length = n;
        result.value.as_typed_data.values = (uint8_t *)buffer;

        Dart_PostCObject_DL(options->port, &result);
    }

    pthread_cleanup_pop(1);

    return NULL;
}

static void start_read_thread(PtyHandle *handle, Dart_Port port)
{
    ReadLoopOptions *options = malloc(sizeof(ReadLoopOptions));

    options->fd = handle->ptm;

    options->port = port;

    options->mutex = &handle->mutex;

    options->waitForReadAck = handle->ackRead;

    if (pthread_create(&handle->reader, NULL, &read_loop, options) != 0)
    {
        free(options);
        return;
    }

    handle->reader_started = 1;
}

typedef struct WaitExitOptions
{
    int pid;

    Dart_Port port;

} WaitExitOptions;

static void *wait_exit_thread(void *arg)
{
    WaitExitOptions *options = (WaitExitOptions *)arg;

    int status;

    waitpid(options->pid, &status, 0);

    if (WIFEXITED(status))
    {
        Dart_PostInteger_DL(options->port, WEXITSTATUS(status));
    }
    else if (WIFSIGNALED(status))
    {
        Dart_PostInteger_DL(options->port, -WTERMSIG(status));
    }

    /* Séance: thread-owned, freed here — upstream never released it. */
    free(options);

    return NULL;
}

static void start_wait_exit_thread(PtyHandle *handle, Dart_Port port)
{
    WaitExitOptions *options = malloc(sizeof(WaitExitOptions));

    options->pid = handle->pid;

    options->port = port;

    if (pthread_create(&handle->waiter, NULL, &wait_exit_thread, options) != 0)
    {
        free(options);
        return;
    }

    handle->waiter_started = 1;
}

static void set_environment(char **environment)
{
    if (environment == NULL)
    {
        return;
    }

    while (*environment != NULL)
    {
        putenv(*environment);
        environment++;
    }
}

FFI_PLUGIN_EXPORT PtyHandle *pty_create(PtyOptions *options)
{
    struct winsize ws;

    ws.ws_row = options->rows;
    ws.ws_col = options->cols;

    int ptm;

    int pid = pty_forkpty(&ptm, NULL, NULL, &ws);

    if (pid < 0)
    {
        error_message = "pty_forkpty failed";
        perror("pty_forkpty");
        return NULL;
    }

    if (pid == 0)
    {
        set_environment(options->environment);

        if (options->working_directory != NULL && strlen(options->working_directory) > 0)
        {
            chdir(options->working_directory);
        }

        int ok = execvp(options->executable, options->arguments);

        if (ok < 0)
        {
            perror("execvp");
            /* Séance: upstream fell through here — the child returned from
               pty_create and kept running a copy of the host process. A
               failed exec must die, not become a second VM. */
            _exit(127);
        }
    }

    PtyHandle *handle = (PtyHandle *)malloc(sizeof(PtyHandle));

    handle->ptm = ptm;
    handle->pid = pid;
    pthread_mutex_init(&handle->mutex, NULL);
    handle->ackRead = options->ackRead;
    handle->reader_started = 0;
    handle->waiter_started = 0;
    handle->closed = 0;

    start_read_thread(handle, options->stdout_port);

    start_wait_exit_thread(handle, options->exit_port);

    return handle;
}

FFI_PLUGIN_EXPORT void pty_write(PtyHandle *handle, char *buffer, int length)
{
    write(handle->ptm, buffer, length);
}

FFI_PLUGIN_EXPORT void pty_ack_read(PtyHandle *handle)
{
    if (handle->ackRead)
    {
        // frees the mutex so that the next chunk of data can be read
        pthread_mutex_unlock(&handle->mutex);
    }
}

FFI_PLUGIN_EXPORT int pty_resize(PtyHandle *handle, int rows, int cols)
{
    struct winsize ws;

    ws.ws_row = rows;
    ws.ws_col = cols;

    return ioctl(handle->ptm, TIOCSWINSZ, &ws);
}

FFI_PLUGIN_EXPORT int pty_getpid(PtyHandle *handle)
{
    return handle->pid;
}

/* Séance: joins the waitpid thread once the child is reaped. Runs on a
   detached thread because the child may still be running when pty_close
   is called — the caller's isolate must not block on it. */
static void *reap_waiter(void *arg)
{
    pthread_t *waiter = (pthread_t *)arg;
    pthread_join(*waiter, NULL);
    free(waiter);
    return NULL;
}

FFI_PLUGIN_EXPORT void pty_close(PtyHandle *handle)
{
    if (handle == NULL || handle->closed)
    {
        return;
    }
    handle->closed = 1;

    if (handle->reader_started)
    {
        /* The reader can be parked inside read() on the master; read(2)
           is a cancellation point, so cancel+join drains it before the fd
           goes away — closing first could let a recycled fd number feed a
           stale read. A reader that already exited joins instantly. */
        pthread_cancel(handle->reader);
        if (!handle->ackRead)
        {
            /* Ack mode can park the reader on the shared mutex, which is
               not a cancellation point — joining it here could hang the
               caller. Séance never enables ackRead; that teardown keeps
               the pre-vendoring behaviour (hang up, leave the rest). */
            pthread_join(handle->reader, NULL);
        }
    }

    /* Closing the master is the hangup: the kernel SIGHUPs the foreground
       process group of the child's session. */
    close(handle->ptm);

    if (!handle->ackRead || !handle->reader_started)
    {
        pthread_mutex_destroy(&handle->mutex);

        if (handle->waiter_started)
        {
            /* The waiter never dereferences this handle — copy its thread
               id out and free the handle now. */
            pthread_t *waiter = malloc(sizeof(pthread_t));
            if (waiter != NULL)
            {
                *waiter = handle->waiter;
                pthread_t reaper;
                if (pthread_create(&reaper, NULL, reap_waiter, waiter) == 0)
                {
                    pthread_detach(reaper);
                }
                else
                {
                    free(waiter);
                }
            }
        }

        free(handle);
    }
}

FFI_PLUGIN_EXPORT char *pty_error(void)
{
    return NULL;
}
