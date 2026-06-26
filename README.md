# cage 🐯

**Go into any project directory, type `cage`, and a throwaway Docker container spins up
with your code in it — then Claude Code launches in `--dangerously-skip-permissions` mode.**

Let the agent run reckless commands (`rm -rf`, force-installs, migrations, `sudo` anything)
without risking your Mac. Your host disk is never bind-mounted: the container works on a
**copy** of your directory, and the agent's work gets out by `git push` (or a rescue
patch/bundle on exit). When Claude exits, the container is destroyed.

It's a generic cousin of a project-specific dev box — point it at *any* repo, in *any*
language, and it figures out the toolchain itself.

```bash
cd ~/some/risky/project
cage
# → detects stack, builds/reuses an image, copies your tree in,
#   launches `claude --dangerously-skip-permissions`
```

---

## How it works

```
  your dir ──copy (tar, host untouched)──▶  ephemeral container
                                                │  claude --dangerously-skip-permissions
                                                │  git commit
                                                ▼
                                   GitHub ◀── git push ── container
  your dir ◀── git pull ── GitHub
```

1. **Detect** — reads `.ruby-version`, `.nvmrc`, `package.json`, `go.mod`, `Cargo.toml`,
   `pyproject.toml`, `.tool-versions`, etc. to learn which runtimes (and versions) the
   project needs.
2. **Image** — builds a cached image (Debian + git + gh + Node + [mise](https://mise.jdx.dev)).
   `mise` installs the project's pinned runtimes. The image tag is a hash of the detected
   stack, so **projects with identical stacks share one image**; no project code is baked in.
3. **Copy in** — your working tree (including uncommitted changes and `.git`) is `tar`'d into
   the container. Big reinstallables like `node_modules` are skipped and reinstalled inside.
4. **Pre-install** — runs the detected install (`bundle install`, `yarn install`, `pip install`,
   `go mod download`, `cargo fetch`…) so the agent starts in a ready project.
5. **Run** — `claude --dangerously-skip-permissions`, as a **non-root** user (with passwordless
   `sudo` *inside* the container, so reckless installs work — the blast radius is the container).
6. **Rescue on exit** — if there's unpushed/uncommitted work, cage stops and offers to
   **push**, open a **shell**, or **dump a patch + git bundle** to the host before destroying
   the container. Nothing is silently lost.

> **Isolation:** the agent can trash the container all it wants; your Mac's filesystem,
> other repos, and host services are untouched. The only things shared are a Claude **login**
> volume and whatever you put in `cage.config`.

---

## Install

```bash
git clone https://github.com/palamedes/cage.git ~/cage
cd ~/cage
./cage setup          # one-time: writes cage.config, imports GitHub token, sets git
                      # identity, does the Claude login, and symlinks cage onto your PATH
```

`cage setup` is interactive and only needs to run once per machine. After it, just `cd`
into any project and type `cage`.

Requires **Docker Desktop** (running). First build pulls base images + compiles runtimes,
so it's slow once; cached after.

> **Login is one-time, not per-run.** Your Claude login is stored in a shared Docker volume
> (`cage_claude`) and reused by every cage. If you skip it in `setup`, the **first** `cage`
> run auto-prompts the login, then never again (until `cage nuke`).

---

## Configure (`cage.config`, gitignored)

`cage setup` writes all of this for you. The file lives next to the `cage` script, is read no
matter which directory you run `cage` in, and is **never committed** (this repo is public).
To change something later, edit `cage.config` directly (`cage config` prints its path) or
re-run a specific importer:

- **Claude auth** — subscription login (`cage login`, stored in the shared `cage_claude`
  volume, never exposing your host `~/.claude`) **or** an API key
  (`export ANTHROPIC_API_KEY="sk-ant-..."` for zero prompts, per-token billing).
- **GitHub** — `cage gh-token` imports a token from your local `gh` (or paste
  `export GH_TOKEN="ghp_..."`). Enables `git push` + `gh` from inside the cage.
- **Commit identity** — `export GIT_USER_NAME=…` / `export GIT_USER_EMAIL=…` so the agent's
  commits are attributed to you.

Run `cage doctor` anytime to verify Docker, config, Claude auth, and the GitHub token.

---

## Commands

| Command | What it does |
|---|---|
| `cage [args]` | Build/reuse this dir's image, copy it in, launch Claude (`--dangerously-skip-permissions`). Extra args pass through to `claude`. Rescues unpushed work on exit. |
| `cage shell` | Same spin-up, but drop into a bash shell instead of Claude. |
| `cage setup` | One-time interactive bootstrap (config, GitHub token, git identity, Claude login, PATH symlink). |
| `cage gh-token` | Import your GitHub token from `gh` into `cage.config`. |
| `cage login` | (Re)do the Claude login into the shared volume — usually automatic on first run. |
| `cage doctor` | Check Docker, config, Claude auth, GitHub token. |
| `cage detect` | Show detected runtimes / image tag / install commands for this dir. |
| `cage build` / `cage rebuild` | Build this dir's image (cache / `--no-cache`) without launching. |
| `cage ps` | List cage containers and images. |
| `cage nuke` | Remove all cage containers, images, and the Claude login volume. |
| `cage config` | Print the path to `cage.config`. |

---

## Getting work out

The intended path is **git**. Inside the cage:

```bash
git checkout -b je-fix/whatever
git add -A && git commit -m "…"
git push -u origin HEAD          # uses GH_TOKEN over HTTPS
gh pr create --fill              # gh is installed
```

then on your Mac: `git fetch origin && git checkout je-fix/whatever`.

If you exit with unpushed work (or the dir has no remote), the **rescue prompt** writes
`cage-rescue-<ts>.bundle` (all commits) and `cage-rescue-<ts>-uncommitted.patch` (working
changes) into the project dir:

```bash
git fetch ./cage-rescue-<ts>.bundle '*:*'          # recover committed branches
git apply ./cage-rescue-<ts>-uncommitted.patch      # recover uncommitted changes
```

---

## Reaching a server in the cage (ports)

cage publishes a host port (default **`4000`**, localhost-only) into the container, sets
`PORT` to it, and tells the agent to bind any web server to `0.0.0.0:4000`. So when Claude
starts a server, you open **http://localhost:4000** on your Mac.

This matters because a server the agent runs *inside* the container is otherwise invisible to
your Mac — and "I verified `localhost:3000` returns 200" is true *in the container* but
unreachable from outside. cage's injected guidance makes the agent bind to the published
port and report the URL you can actually open.

Change or add ports with `export CAGE_PORTS="4000 5173"` in `cage.config` (space-separated;
`""` publishes nothing). Ports are fixed when the container is created, so changing this
takes effect on the next `cage` run.

## Session memory (`.cage` log)

Because every cage is ephemeral and your dir is only ever a *copy*, cage keeps a small
`.cage` file in the project so future cages know what happened here:

- On spin-up, cage prints the previous notes and makes `.cage` available at `/work/.cage`.
- During the session, Claude is told (via an appended system prompt) to read `/work/.cage`
  for context and append a short dated summary of what it did before finishing.
- On exit, cage appends a mechanical line (commits / branches pushed), caps the file to the
  most recent 40 entries, copies it back to the host, and commits it **as its own commit**.

```
## 2026-06-18 10:42
_Added rate-limiting to the API and a spec; pushed je-fix/ratelimit. TODO: wire the Redis backend._
— cage: pushed je-fix/ratelimit (a1b2c3d); 2 commit(s), 5 file(s)
```

`.cage` is a **tracked, committed file** — git is the only durable store for an ephemeral
cage, so committing is what makes the log survive teardown. It's committed separately from
your code (a no-op session still records its log) and kept secret-free (only branch names,
short SHAs, and counts — never tokens or remote URLs).

The log is capped at the **40 most recent entries**; older ones are trimmed off the top but
are *not* lost — every trimmed entry still lives permanently in history (`git log -- .cage`).
Earlier versions of cage git-*excluded* `.cage`; cage now removes that `.git/info/exclude`
entry automatically the next time it runs. If the dir isn't a git repo, cage just keeps the
local file. Disable the whole thing with `export CAGE_BREADCRUMB=0` in `cage.config`.

## Notes & limitations

- **Ephemeral by design.** Each `cage` is a fresh container destroyed on exit. In-container
  state (installed deps, shell history) does **not** persist between sessions — only your
  pushed commits / rescued patches do. The Claude login *does* persist (shared volume).
- **Requires a remote for push.** No remote? Use the rescue dump, or `git init` + add one.
- **Big dependency installs repeat each session** (deps aren't cached between ephemeral
  runs). Fine for most repos; a per-project dep-cache volume may be added later.
- **Auto-detect covers** Ruby, Node, Python, Go, Rust, and `.tool-versions`. Anything else,
  the agent can `sudo apt-get install` / `mise use` inside the cage.
- **Public repo:** no secrets are committed. Everything sensitive lives in `cage.config`.

## What lives where

- **Committed:** `cage`, `lib/detect.sh`, `templates/Dockerfile`, `templates/entrypoint.sh`,
  `cage.config.example`, `README.md`.
- **Gitignored:** `cage.config` (your secrets) and `cage-rescue-*` artifacts.
- **Docker:** per-stack images (`cage:<hash>`) and the `cage_claude` login volume.

## Installing on CachyOS / Arch Linux

The main instructions assume macOS + Docker Desktop. On Arch-based distros (CachyOS, Manjaro,
EndeavourOS…) the only real difference is Docker: you want **Docker Engine** from the official
repos, **not** Docker Desktop. Most of what cage needs (`git`, `bash`, GNU `tar`, `sha256sum`)
ships with the base system already. `osascript` is macOS-only and used solely by `cage paste`;
the rest of cage doesn't touch it, so you can ignore it on Linux.

**1. Docker Engine — required (the only hard dependency):**

```bash
sudo pacman -S docker
sudo systemctl enable --now docker.service

# Let cage talk to Docker as your user — cage runs `docker` with no sudo.
sudo usermod -aG docker $USER
```

Then **log out of your session and back in** so the new group takes effect (a fresh terminal tab
is *not* enough — it inherits the old login session's groups; `newgrp docker` works for one shell
in a pinch). Verify with:

```bash
id -nG | tr ' ' '\n' | grep -x docker    # should print "docker"
docker info                              # should succeed with no sudo
```

> If `docker info` shows `permission denied while trying to connect to the docker API at
> unix:///var/run/docker.sock`, the daemon is fine — your **current shell** just hasn't picked up
> the `docker` group yet. Log out/in (or `newgrp docker`) and retry.

**2. GitHub CLI — optional (enables `git push` + `gh` PRs from inside the cage):**

```bash
sudo pacman -S github-cli
gh auth login
```

Without it you can still paste a `GH_TOKEN` into `cage.config` by hand.

**3. Bootstrap cage:**

```bash
cd ~/path/to/cage
./cage setup
```

> **PATH symlink on Linux:** `cage setup` looks for `/opt/homebrew/bin`, `/usr/local/bin`, or
> `$HOME/bin` to symlink `cage` into. On Arch, `/usr/local/bin` exists but isn't user-writable and
> `~/bin` may not exist, so the symlink step may be skipped. Just do it yourself:
>
> ```bash
> mkdir -p ~/.local/bin && ln -sf "$(pwd)/cage" ~/.local/bin/cage   # ensure ~/.local/bin is on $PATH
> ```
