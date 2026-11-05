# Screenshot host for Hoshi's App Store screenshots and App Preview.
# One image, three roles (devbox, gpu-box, prod-api) chosen by compose.yml.
# Everything that reaches the terminal is scripted, so captures are repeatable.
FROM debian:bookworm-slim

ARG HERDR_VERSION=0.9.5
ARG TARGETARCH

RUN apt-get update -qq \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      openssh-server mosh tmux git locales procps curl ca-certificates \
      vim-nox htop iproute2 less python3 bat \
 && sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen >/dev/null \
 && rm -rf /var/lib/apt/lists/*

# Herdr: real Linux build, so Hoshi's discovery and agent list are genuine.
RUN case "${TARGETARCH:-arm64}" in arm64) a=aarch64;; amd64) a=x86_64;; *) echo "unsupported $TARGETARCH"; exit 1;; esac \
 && curl -fsSL -o /usr/local/bin/herdr "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-${a}" \
 && chmod +x /usr/local/bin/herdr

RUN useradd -m -s /bin/bash fcoury && mkdir -p /run/sshd \
 && printf 'PasswordAuthentication yes\nPermitRootLogin no\nAcceptEnv LANG LC_*\n' > /etc/ssh/sshd_config.d/shots.conf

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Hoshi's own source: the open-source app shown working on itself.
RUN git clone -q --depth 60 https://github.com/fcoury/hoshi /home/fcoury/hoshi

COPY home/ /home/fcoury/
COPY bin/ /opt/shots/
RUN chmod +x /opt/shots/*.sh && chown -R fcoury:fcoury /home/fcoury

EXPOSE 22
ENTRYPOINT ["/opt/shots/entrypoint.sh"]
