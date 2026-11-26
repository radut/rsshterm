# Test image for rsshd: Go plus the real programs the e2e drives (tmux, GNU screen, htop, procps for pgrep/ps).
# make rsshd-test builds it; the GitLab job rsshd:test installs the same packages into the same golang image.
ARG GO_IMAGE=golang:1.26-bookworm
FROM ${GO_IMAGE}
RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends tmux screen htop procps >/dev/null \
 && rm -rf /var/lib/apt/lists/*
