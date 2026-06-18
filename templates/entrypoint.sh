#!/usr/bin/env bash
# Runs (as the non-root `cage` user) when the container starts, before `sleep infinity`.
# `cage` copies the working tree in while the container is created (root-owned), so we hand
# /work back to the cage user here, set the commit identity, and wire GH_TOKEN for HTTPS push.
set -u

# Files copied via `docker cp` land root-owned — claim them for the cage user.
sudo chown -R cage:cage /work 2>/dev/null || true

git config --global user.name  "${GIT_USER_NAME:-cage}"
git config --global user.email "${GIT_USER_EMAIL:-cage@localhost}"
git config --global --add safe.directory /work 2>/dev/null || true
git config --global init.defaultBranch main 2>/dev/null || true

# Use a GitHub token (set via `cage gh-token`) for git over HTTPS + gh, since the non-root
# user has no SSH agent. Rewrites both SSH and HTTPS GitHub remotes to the token URL.
if [ -n "${GH_TOKEN:-}" ]; then
  git config --global --replace-all url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "git@github.com:"
  git config --global --add        url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

exec "$@"
