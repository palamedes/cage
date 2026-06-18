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
