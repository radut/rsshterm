#ifndef RSSH_PTY_H
#define RSSH_PTY_H

/// Starts `path` with `argv`/`envp` on a new pseudo-terminal of `rows` x `cols`, in `cwd` (NULL: inherit), as the
/// session leader with the terminal as its controlling tty. Returns 0 and the master fd (close-on-exec) and pid, or
/// -1 with errno set. The child closes every inherited fd above 2, resets signal dispositions and mask, and exits
/// with 127 when execve fails.
int rssh_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                   unsigned short rows, unsigned short cols, int *out_master, int *out_pid);

/// TIOCSWINSZ on the master: the child gets SIGWINCH. Returns 0, or -1 with errno set.
int rssh_pty_set_size(int master, unsigned short rows, unsigned short cols);

#endif
