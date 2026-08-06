FROM condaforge/miniforge3:26.3.2-3

# Environment setup
ENV WORKSPACE=/workspace \
    XDG_CONFIG_HOME=/root/.config \
    PYTHONDONTWRITEBYTECODE=1 \
    TZ=America/Los_Angeles \
    DEBIAN_FRONTEND=noninteractive \
    PATH="/opt/local/bin:$PATH"

# Base dependencies (git is already present in the base image)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    emacs-nox \
    build-essential \
    tzdata \
    && ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# conda environment: Python, ROOT (CERN), and the scientific stack
COPY environment.yml /tmp/environment.yml
RUN conda env update -n base -f /tmp/environment.yml && \
    conda clean -afy && \
    rm /tmp/environment.yml

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

# claude-code
# We use --ignore-scripts for security, then manually trigger the official Anthropic binary download
ARG CLAUDE_CODE_VERSION=2.1.223
RUN npm install -g --ignore-scripts @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} && \
    cd $(npm root -g)/@anthropic-ai/claude-code && \
    node install.cjs

# Custom repo-local skills
COPY skills/ /opt/config/claude/skills/

# claude config
COPY settings.json /opt/config/claude/settings.json

RUN mkdir -p /opt/local/bin
COPY claude-cborg /opt/local/bin

WORKDIR /workspace

# Entrypoint copies settings into /root/.claude, activates the conda base env, then execs the command
ENTRYPOINT ["/bin/bash", "-c", "mkdir -p /root/.claude && cp -a /opt/config/claude/. /root/.claude/ && . /opt/conda/etc/profile.d/conda.sh && conda activate base && exec \"$@\"", "--"]

CMD ["/bin/bash"]
