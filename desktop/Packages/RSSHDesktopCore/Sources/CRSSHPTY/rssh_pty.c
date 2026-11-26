#include "rssh_pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif

int rssh_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                   unsigned short rows, unsigned short cols, int *out_master, int *out_pid) {
    struct winsize size = {0};
    size.ws_row = rows;
    size.ws_col = cols;
    long open_max = sysconf(_SC_OPEN_MAX);
    int max_fd = (open_max <= 0 || open_max > 65536) ? 65536 : (int)open_max;

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) return -1;
    if (pid == 0) {
        // Only async-signal-safe calls from here to execve.
        for (int fd = 3; fd < max_fd; fd++) close(fd);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        for (int sig = 1; sig < NSIG; sig++) {
            if (sig != SIGKILL && sig != SIGSTOP) signal(sig, SIG_DFL);
        }
        if (cwd != NULL && chdir(cwd) != 0) { /* stay where we are, like other terminals */ }
        execve(path, argv, envp);
        _exit(127);
    }
    int flags = fcntl(master, F_GETFD);
    if (flags >= 0) fcntl(master, F_SETFD, flags | FD_CLOEXEC);
    *out_master = master;
    *out_pid = (int)pid;
    return 0;
}

int rssh_pty_set_size(int master, unsigned short rows, unsigned short cols) {
    struct winsize size = {0};
    size.ws_row = rows;
    size.ws_col = cols;
    return ioctl(master, TIOCSWINSZ, &size);
}
