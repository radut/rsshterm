# Build and smoke-test image for the Linux VTE spike.
#   docker build -t rssh-linux-vte-spike desktop/spikes/linux-vte
#   docker run --rm -v "$PWD/desktop/spikes/linux-vte":/w -w /w rssh-linux-vte-spike ./smoke-test.sh
FROM swift:6.4-noble
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev pkg-config \
      xvfb xauth dbus-x11 \
 && rm -rf /var/lib/apt/lists/*
ENV GTK_A11Y=none GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1
