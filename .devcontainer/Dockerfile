ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.3.2
ARG DEBIAN_VERSION=trixie-20260202-slim

ARG IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"

FROM ${IMAGE} AS devcontainer

ARG TZ
ENV TZ="$TZ"

# Install basic development tools, iptables/ipset, and build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    less \
    git \
    procps \
    sudo \
    fzf \
    zsh \
    unzip \
    curl \
    ca-certificates \
    iptables \
    ipset \
    iproute2 \
    jq \
    nano \
    vim \
    locales \
    build-essential \
    tinyproxy \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create non-root dev user
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=$USER_UID
RUN groupadd --gid $USER_GID $USERNAME \
    && useradd --uid $USER_UID --gid $USER_GID -m $USERNAME \
    && echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USERNAME \
    && chmod 0440 /etc/sudoers.d/$USERNAME

# Persist shell history
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    && mkdir /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R $USERNAME /commandhistory

# Set DEVCONTAINER environment variable
ENV DEVCONTAINER=true

# Create workspace and config directories
RUN mkdir -p /workspace /home/$USERNAME/.claude /home/$USERNAME/.mix /home/$USERNAME/.hex \
    && chown -R $USERNAME:$USERNAME /workspace /home/$USERNAME/.claude /home/$USERNAME/.mix /home/$USERNAME/.hex

WORKDIR /workspace

# Set up tinyproxy forward proxy
RUN mkdir -p /var/log/tinyproxy /run/tinyproxy \
    && chown -R nobody:nogroup /var/log/tinyproxy /run/tinyproxy
COPY tinyproxy.conf /etc/tinyproxy/tinyproxy.conf
COPY allowed-domains.txt /usr/local/etc/allowed-domains.txt

# Switch to non-root user
USER $USERNAME

# Install Hex and Rebar
RUN mix local.hex --force && mix local.rebar --force

# Set the default shell to zsh
ENV SHELL=/bin/zsh

# Set the default editor
ENV EDITOR=nano
ENV VISUAL=nano

# Default powerline10k theme
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(curl -fsSL https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
    -p git \
    -p fzf \
    -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
    -a "source /usr/share/doc/fzf/examples/completion.zsh" \
    -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    -x

# Install Claude Code (native binary, no Node.js required)
ENV PATH=$PATH:/home/$USERNAME/.local/bin
RUN curl -fsSL https://claude.ai/install.sh | bash

# Copy and set up scripts
COPY init-firewall.sh link-claude-project.sh /usr/local/bin/
USER root
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/link-claude-project.sh && \
    echo "$USERNAME ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/$USERNAME-firewall && \
    chmod 0440 /etc/sudoers.d/$USERNAME-firewall
USER $USERNAME
