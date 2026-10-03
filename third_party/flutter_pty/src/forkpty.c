/* Séance: _GNU_SOURCE (for ptsname_r) is already defined by
   flutter_pty.h, which this TU includes before any system header. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <fcntl.h>
#include <pthread.h>
#include <unistd.h>
#include <termios.h>
#include <sys/ioctl.h>

pid_t pty_forkpty(
    int *master,
    int *slave,
    const struct termios *termp,
    const struct winsize *winp)
{
    /* Séance: a NULL out-parameter used to crash the caller. */
    if (master == NULL)
    {
        return -1;
    }

    int ptm = open("/dev/ptmx", O_RDWR | O_NOCTTY);

    if (ptm < 0)
    {
        return -1;
    }

    fcntl(ptm, F_SETFD, FD_CLOEXEC);

    /* Séance: every failure past this point must close what is already
       open — upstream returned -1 and leaked ptm (and pts) each time. */
    if (grantpt(ptm) || unlockpt(ptm))
    {
        close(ptm);
        return -1;
    }

    /* Séance: ptsname_r, not ptsname — the static buffer upstream used is
       not safe once two isolates can spawn concurrently. */
    char devname[128];

    if (ptsname_r(ptm, devname, sizeof(devname)) != 0)
    {
        close(ptm);
        return -1;
    }

    int pts = open(devname, O_RDWR | O_NOCTTY);
    if (pts < 0)
    {
        close(ptm);
        return -1;
    }

    if (termp)
    {
        tcsetattr(pts, TCSAFLUSH, termp);
    }

    if (winp)
    {
        ioctl(pts, TIOCSWINSZ, winp);
    }

    pid_t pid = fork();

    if (pid < 0)
    {
        close(pts);
        close(ptm);
        return -1;
    }

    if (pid == 0)
    {
        /* Séance: match real forkpty — the child must not keep the master
           (FD_CLOEXEC already covers the exec case), and a forked child
           error must _exit so it never runs the parent's atexit handlers
           or flushes duplicated stdio buffers. */
        close(ptm);
        setsid();
        if (ioctl(pts, TIOCSCTTY, (char *)NULL) == -1)
            _exit(-1);

        dup2(pts, STDIN_FILENO);
        dup2(pts, STDOUT_FILENO);
        dup2(pts, STDERR_FILENO);

        if (pts > 2)
        {
            close(pts);
        }
    }
    else
    {
        *master = ptm;
        if (slave)
        {
            *slave = pts;
        }
        else
        {
            /* Séance: a caller that asks for no slave fd must not leak it —
               the parent held a second slave descriptor open for the life
               of the process. */
            close(pts);
        }
    }

    return pid;
}
