#!/bin/sh
# $RDP_PASSWORD is a throwaway per-run password from integration.sh.
set -eu
printf 'rdp:%s\n' "$RDP_PASSWORD" | chpasswd
xrdp-sesman --nodaemon &
exec xrdp --nodaemon
