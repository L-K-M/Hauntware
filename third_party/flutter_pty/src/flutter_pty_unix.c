
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
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

    /* Séance: self-pipe that wakes the reader out of poll() — Bionic
       provides no pthread_cancel, and closing the master first could let
       a recycled fd number feed a stale read. stop_fd[0] is read by the
       reader, stop_fd[1] is written once by pty_close. */
    int stop_fd[2];

    int closed;

} PtyHandle;

typedef struct ReadLoopOptions
{
    int fd;

    int stop_fd;

    pthread_mutex_t *mutex;

    Dart_Port port;

    bool waitForReadAck;

} ReadLoopOptions;

char *error_message = NULL;

/* Séance: synchronous reaps in the failure paths retry EINTR — an
   interrupted waitpid would leave the killed child a zombie. */
static void reap_child(pid_t pid)
{
    pid_t rc;
    do
    {
        rc = waitpid(pid, NULL, 0);
    } while (rc < 0 && errno == EINTR);
    (void)rc;
}

static void *read_loop(void *arg)
{
    ReadLoopOptions *options = (ReadLoopOptions *)arg;

    char buffer[1024];

    /* Séance: poll() waits on the master and the stop pipe together, so
       pty_close can wake this thread with a byte instead of a
       cancellation — portable to Bionic. The stop fd is checked first:
       a close in progress drops whatever output was still pending. This
       thread frees its own options on every exit path. */
    struct pollfd fds[2];

    fds[0].fd = options->fd;
    fds[0].events = POLLIN;
    fds[1].fd = options->stop_fd;
    fds[1].events = POLLIN;

    while (1)
    {
        if (options->waitForReadAck)
        {
            // if we are in ack mode then we get a mutex here that is
            // freed again once the chunk of data has been processed
            pthread_mutex_lock(options->mutex);
        }

        if (poll(fds, 2, -1) < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
            break;
        }

        if (fds[1].revents != 0)
        {
            break;
        }

        if (fds[0].revents == 0)
        {
            continue;
        }

        ssize_t n = read(options->fd, buffer, sizeof(buffer));

        if (n < 0)
        {
            if (errno == EINTR)
            {
                continue;
            }
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

    free(options);

    return NULL;
}

static int start_read_thread(PtyHandle *handle, Dart_Port port)
{
    ReadLoopOptions *options = malloc(sizeof(ReadLoopOptions));

    /* Séance: unchecked malloc used to NULL-deref, and a silent give-up
       handed the caller a live handle that could never produce output. */
    if (options == NULL)
    {
        return -1;
    }

    options->fd = handle->ptm;

    options->stop_fd = handle->stop_fd[0];

    options->port = port;

    options->mutex = &handle->mutex;

    options->waitForReadAck = handle->ackRead;

    if (pthread_create(&handle->reader, NULL, &read_loop, options) != 0)
    {
        free(options);
        return -1;
    }

    handle->reader_started = 1;
    return 0;
}

typedef struct WaitExitOptions
{
    int pid;

    Dart_Port port;

} WaitExitOptions;

static void *wait_exit_thread(void *arg)
{
    WaitExitOptions *options = (WaitExitOptions *)arg;

    int status = 0;
    pid_t rc;

    /* Séance: upstream fed `status` into WIFEXITED/WIFSIGNALED even when
       waitpid failed — an interrupted call read uninitialized stack and
       could fabricate an exit code, which would disarm a caller's kill
       escalation while the child still runs. Retry EINTR; on any other
       failure post nothing — no exit event means "not proven dead". */
    do
    {
        rc = waitpid(options->pid, &status, 0);
    } while (rc < 0 && errno == EINTR);

    if (rc > 0)
    {
        if (WIFEXITED(status))
        {
            Dart_PostInteger_DL(options->port, WEXITSTATUS(status));
        }
        else if (WIFSIGNALED(status))
        {
            Dart_PostInteger_DL(options->port, -WTERMSIG(status));
        }
    }

    /* Séance: thread-owned, freed here — upstream never released it. */
    free(options);

    return NULL;
}

static int start_wait_exit_thread(PtyHandle *handle, Dart_Port port)
{
    WaitExitOptions *options = malloc(sizeof(WaitExitOptions));

    if (options == NULL)
    {
        return -1;
    }

    options->pid = handle->pid;

    options->port = port;

    if (pthread_create(&handle->waiter, NULL, &wait_exit_thread, options) != 0)
    {
        free(options);
        return -1;
    }

    handle->waiter_started = 1;
    return 0;
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
    struct winsize ws = {0};

    ws.ws_row = options->rows;
    ws.ws_col = options->cols;

    error_message = NULL;

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

    /* Séance: unchecked malloc — a NULL handle must not dereference or
       strand the forked child. */
    if (handle == NULL)
    {
        error_message = "out of memory";
        kill(pid, SIGKILL);
        reap_child(pid);
        close(ptm);
        return NULL;
    }

    handle->ptm = ptm;
    handle->pid = pid;
    pthread_mutex_init(&handle->mutex, NULL);
    handle->ackRead = options->ackRead;
    handle->reader_started = 0;
    handle->waiter_started = 0;
    handle->stop_fd[0] = -1;
    handle->stop_fd[1] = -1;
    handle->closed = 0;

    /* Séance: the pipe exists to wake the reader out of poll() — Bionic
       has no pthread_cancel. Created after the fork so this child never
       inherits either end, marked close-on-exec so later siblings don't
       either. */
    if (pipe(handle->stop_fd) < 0 ||
        fcntl(handle->stop_fd[0], F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(handle->stop_fd[1], F_SETFD, FD_CLOEXEC) < 0)
    {
        error_message = "stop pipe failed";
        kill(pid, SIGKILL);
        reap_child(pid);
        if (handle->stop_fd[0] >= 0)
        {
            close(handle->stop_fd[0]);
        }
        if (handle->stop_fd[1] >= 0)
        {
            close(handle->stop_fd[1]);
        }
        close(ptm);
        pthread_mutex_destroy(&handle->mutex);
        free(handle);
        return NULL;
    }

    /* Séance: a worker thread that never started used to hand Dart a
       live handle that produces no output or no exit event — a broken
       session indistinguishable from a hang. Both starters are fatal
       now; the teardown mirrors pty_close's tail. */
    if (start_read_thread(handle, options->stdout_port) < 0 ||
        start_wait_exit_thread(handle, options->exit_port) < 0)
    {
        error_message = "failed to start pty worker threads";

        if (handle->reader_started)
        {
            /* Same EINTR retry as pty_close: a lost wake would leave the
               join blocked on a reader parked in poll(). */
            while (write(handle->stop_fd[1], "x", 1) < 0 && errno == EINTR)
            {
            }
            pthread_join(handle->reader, NULL);
        }

        kill(handle->pid, SIGKILL);
        reap_child(handle->pid);
        close(handle->ptm);
        close(handle->stop_fd[0]);
        close(handle->stop_fd[1]);

        /* handle->waiter_started is always false here: reaching this
           branch means one starter returned <0, so start_wait_exit_thread
           either failed or never ran — there is no waiter to reap. */

        pthread_mutex_destroy(&handle->mutex);
        free(handle);
        return NULL;
    }

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
    struct winsize ws = {0};

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
        /* A byte on the stop pipe makes the reader exit poll() on its
           own and unwind — the portable replacement for pthread_cancel,
           which Bionic does not declare. Both pipe ends stay open until
           the cleanup below, so a one-byte write can only fail
           transiently — retry EINTR or the join below would block on a
           reader still parked in poll(). A reader that already exited
           simply never consumes the byte, and joins instantly. */
        while (write(handle->stop_fd[1], "x", 1) < 0 && errno == EINTR)
        {
        }
        if (!handle->ackRead)
        {
            /* Ack mode can park the reader on the shared mutex, which
               poll() never sees — joining it here could hang the caller.
               Séance never enables ackRead; that teardown keeps the
               pre-vendoring behaviour (hang up, leave the rest). */
            pthread_join(handle->reader, NULL);
        }
    }

    /* Closing the master is the hangup: the kernel SIGHUPs the foreground
       process group of the child's session. The reader is already gone
       by now, so no recycled fd number can feed it a stale read. */
    close(handle->ptm);

    if (!handle->ackRead || !handle->reader_started)
    {
        if (handle->stop_fd[0] >= 0)
        {
            close(handle->stop_fd[0]);
        }
        if (handle->stop_fd[1] >= 0)
        {
            close(handle->stop_fd[1]);
        }

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
    /* Séance: pty_create records the failure reason here; returning NULL
       unconditionally made it write-only dead state. Cleared at the top
       of each pty_create so a stale message is never reported. */
    return error_message;
}
