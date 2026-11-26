# Spike: Swift + GTK4 + VTE on Linux

Throw-away proof that a Swift executable can open a GTK4 window holding a VTE terminal widget through plain C interop
(no Swift GTK wrapper), and that this builds and runs in CI with no display. Findings and the stack decision are in
[docs/research/desktop.md](../../../docs/research/desktop.md).

| File | What |
|---|---|
| `Package.swift` | system library `CGtkVte` (pkg-config `vte-2.91-gtk4`, which pulls in `gtk4`) + executable |
| `Sources/CGtkVte/` | module map and `shim.h`: the GObject cast macros (`GTK_WINDOW`, `VTE_TERMINAL`, `G_APPLICATION`) and `g_signal_connect`, which Swift cannot import, as `static inline` functions |
| `Sources/LinuxVteSpike/main.swift` | `GtkApplication` → `GtkApplicationWindow` → `VteTerminal`, `vte_terminal_spawn_async($SHELL)` |
| `Dockerfile` | `swift:6.4-noble` + `libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev` + Xvfb |
| `smoke-test.sh` | builds, runs `--smoke` under `xvfb-run`, checks the child's output was read back from the VTE screen |

## Run

Build the image and run the smoke test (from the repo root):

```bash
docker build -t rssh-linux-vte-spike desktop/spikes/linux-vte
docker run --rm -v "$PWD/desktop/spikes/linux-vte":/w -w /w rssh-linux-vte-spike ./smoke-test.sh
```

Expected tail:

```text
spawned-pid: 238
screen-has-marker: yes
child-exit-status: 0
PASS: GTK4 window + VTE terminal ran a child and showed its output
```

On an Ubuntu 24.04 desktop with the same `-dev` packages and a Swift 6.x toolchain, `swift run` opens a real window
with your `$SHELL` in it.

## What `--smoke` proves

The child is `/bin/sh -c "printf '%s-%s\n' rssh-spike marker"`, so the marker text appears only if the child really ran
on VTE's PTY and VTE parsed its output; `child-exited` then reads the screen with `vte_terminal_get_text_format` and
the process exits 0 only when the marker is there and the child's status is 0. A 10 s timeout fails the run.

## Versions seen (Ubuntu 24.04 noble)

GTK 4.14.5, libadwaita 1.5.0, VTE 0.76.0, Swift 6.4.

## Notes for the real app

- `--smoke` is filtered by passing only `argv[0]` to `g_application_run`; the real app registers its options with
  `g_application_add_main_option_entries` instead.
- Callbacks are `@convention(c)` closures with globals (`nonisolated(unsafe)`); the real app passes `Unmanaged`
  Swift objects as `user_data` and keeps all GTK calls on the main thread.
- `GTK_A11Y=none` only silences the missing accessibility bus inside the container.
