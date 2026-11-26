# xrdp + xorgxrdp with one user whose session is an xterm: the RDP server of the FreeRDP spike.
FROM ubuntu:24.04
RUN apt-get -qq update && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y --no-install-recommends \
      xrdp xorgxrdp xterm dbus-x11 xclip \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash rdp \
    && printf '#!/bin/sh\n(while true; do printf "rSshTerm clipboard test" | timeout 2 xclip -quiet -selection clipboard; done) >/dev/null 2>&1 &\nexec xterm -geometry 80x24+10+10 -e sh -c "echo rSshTerm RDP test; exec bash"\n' \
       > /home/rdp/.xsession && chmod +x /home/rdp/.xsession && chown rdp:rdp /home/rdp/.xsession
COPY entrypoint.sh /entrypoint.sh
EXPOSE 3389
ENTRYPOINT ["/entrypoint.sh"]
