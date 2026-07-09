FROM python:3.11-slim

# Environment setup
ENV WORKSPACE=/workspace \
    XDG_CONFIG_HOME=/root/.config \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/workspace/venv/bin:/opt/local/bin:$PATH"

# Base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    nodejs \
    npm \
    build-essential \
    emacs-nox \
    && pip install --no-cache-dir --upgrade pip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# claude-code
# We use --ignore-scripts for security, then manually trigger the official Anthropic binary download
ARG CLAUDE_CODE_VERSION=2.1.201
RUN npm install -g --ignore-scripts @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && \
    cd $(npm root -g)/@anthropic-ai/claude-code && \
    node install.cjs

# superpowers
# ARG SUPERPOWERS_VERSION=v5.1.0
# ARG SUPERPOWERS_REPO=https://github.com/obra/superpowers.git
ARG SUPERPOWERS_VERSION=v6.0.3
ARG SUPERPOWERS_REPO=https://github.com/pcvelz/superpowers.git
RUN mkdir -p /opt/config/claude/plugins \
             /opt/config/claude/skills && \
    git clone $SUPERPOWERS_REPO /opt/superpowers && \
    git -C /opt/superpowers checkout $SUPERPOWERS_VERSION && \
    cp -r /opt/superpowers/skills/* /opt/config/claude/skills/

# claude config
COPY settings.json /opt/config/claude/settings.json

RUN mkdir -p /opt/local/bin
COPY claude-cborg /opt/local/bin

WORKDIR /workspace

# Entrypoint copies settings into /root/.claude, then execs the command
ENTRYPOINT ["/bin/bash", "-c", "mkdir -p /root/.claude && cp -a /opt/config/claude/. /root/.claude/ && exec \"$@\"", "--"]

CMD ["/bin/bash"]
