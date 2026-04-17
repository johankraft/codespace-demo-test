FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN if [ -f /etc/apt/sources.list.d/yarn.list ]; then mv /etc/apt/sources.list.d/yarn.list /etc/apt/sources.list.d/yarn.list.disabled; fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        xfce4 \
        xfce4-terminal \
        tightvncserver \
        novnc \
        websockify \
        xfonts-base \
        dbus-x11 \
        wget \
        curl \
        ca-certificates \
        iproute2 \
        procps \
        psmisc \
        tar \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
