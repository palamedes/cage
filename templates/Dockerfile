# syntax=docker/dockerfile:1.7
#
# cage runtime image — generic, multi-language throwaway sandbox for Claude Code.
#
# Layout (so projects share cache):
#   • Everything up to "project runtimes" is IDENTICAL for every project → one cached base.
#   • mise installs the project's detected runtimes (CAGE_RUNTIMES build-arg) in the final
#     layer, so only differing stacks produce a new image.
#
# No project code is baked in — `cage` copies the working tree into the running container.
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    CLAUDE_CONFIG_DIR=/home/cage/.cage-claude \
    DISABLE_AUTOUPDATER=1

# --- System packages: build toolchain + common native-build headers + CLI tools --------
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-client \
      build-essential pkg-config \
      libssl-dev zlib1g-dev libyaml-dev libffi-dev libreadline-dev libgdbm-dev \
      libpq-dev libsqlite3-dev sqlite3 \
      ripgrep jq sudo tzdata gnupg unzip xz-utils procps less \
    && rm -rf /var/lib/apt/lists/*

# --- GitHub CLI (gh) — PRs / posting from inside the cage; auth via GH_TOKEN at runtime ---
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -qq && apt-get install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# --- Fixed Node (for Claude Code itself) — identical across all projects (max cache) ------
ARG NODE_MAJOR=22
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/* && \
    npm install -g @anthropic-ai/claude-code && \
    npm cache clean --force

# --- Non-root user with passwordless sudo (reckless INSIDE the container is fine) ---------
ARG APP_UID=1000
ARG APP_GID=1000
RUN groupadd -g "${APP_GID}" cage && \
    useradd -m -u "${APP_UID}" -g "${APP_GID}" -s /bin/bash cage && \
    echo 'cage ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/cage && chmod 0440 /etc/sudoers.d/cage && \
    mkdir -p /work && chown -R cage:cage /work

USER cage
WORKDIR /work

# --- mise: project-pinned language runtimes (ruby/python/go/rust/node…) -------------------
RUN curl -fsSL https://mise.run | sh
ENV PATH="/home/cage/.local/share/mise/shims:/home/cage/.local/bin:${PATH}"
RUN { echo 'export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"'; \
      echo 'eval "$(~/.local/bin/mise activate bash)" 2>/dev/null || true'; \
    } | tee -a ~/.bashrc >> ~/.profile

# Install the project's detected runtimes. Empty => base image (shared by all stackless dirs).
ARG CAGE_RUNTIMES=""
RUN if [ -n "${CAGE_RUNTIMES}" ]; then \
      ~/.local/bin/mise use -g ${CAGE_RUNTIMES} && ~/.local/bin/mise install -y; \
    fi

# Claude config dir mountpoint, owned by cage so the named login volume is writable.
RUN mkdir -p "${CLAUDE_CONFIG_DIR}"

COPY --chown=cage:cage --chmod=0755 entrypoint.sh /usr/local/bin/cage-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/cage-entrypoint.sh"]
CMD ["sleep", "infinity"]
