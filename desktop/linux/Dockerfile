# Build, test and smoke-test image for the Linux app (desktop/linux).
#   docker build -t rsshterm-linux desktop/linux
#   make test-desktop-linux-app
# Build deps of the app: libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev pkg-config zlib1g-dev freerdp3-dev.
# The rest is for the smoke test under Xvfb: keys typed with xdotool, screenshots with ImageMagick, sshd + ssh for SSH tabs.
FROM swift:6.4-noble
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libgtk-4-dev libadwaita-1-dev libvte-2.91-gtk4-dev pkg-config zlib1g-dev freerdp3-dev \
      desktop-file-utils appstream xvfb xauth dbus-x11 xdotool imagemagick openssh-client openssh-server fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*
ENV GTK_A11Y=none GSK_RENDERER=cairo LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1 GDK_BACKEND=x11
