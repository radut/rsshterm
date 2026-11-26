# TigerVNC (Xvnc) with a VNC password: an RFB 3.8 server offering security type 2 only, 800x600, with an xterm
# drawn on it so frames carry pixels.
FROM ubuntu:24.04
RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends \
      tigervnc-standalone-server tigervnc-tools xterm xclip \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
EXPOSE 5900
ENTRYPOINT ["/entrypoint.sh"]
