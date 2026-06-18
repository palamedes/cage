#!/usr/bin/env bash
# detect.sh — figure out a project's toolchain from its files. Pure host bash (no Docker).
# Sourced by `cage`. Kept bash 3.2-compatible (no associative arrays).
#
#   detect_runtimes <dir>  -> space-separated "tool@version" for mise (baked into the image)
#   detect_install  <dir>  -> newline-separated shell commands to install deps (run at runtime)

# Map asdf plugin names to the names mise expects.
_rt_norm() {
  case "$1" in
    nodejs) printf node ;;
    golang) printf go ;;
    *)      printf '%s' "$1" ;;
  esac
}

# Append "tool@ver" to RT unless that tool is already present (first definition wins).
_rt_add() {
  local tool; tool="$(_rt_norm "$1")"
  case " $RT " in *" $tool@"*) ;; *) RT="${RT:+$RT }$tool@$2" ;; esac
}

# Trim whitespace + an optional leading "ruby-"/"v" style prefix from a version token.
_clean_ver() { printf '%s' "$1" | tr -d '[:space:]' | sed -E 's/^(ruby-|v)//'; }

detect_runtimes() {
  local d="$1"; RT=""

  # .tool-versions (asdf/mise) wins — it's an explicit pin of everything.
  if [[ -f "$d/.tool-versions" ]]; then
    while read -r tool ver _; do
      [[ -z "$tool" || "$tool" == \#* ]] && continue
      [[ -n "$ver" ]] && _rt_add "$tool" "$ver"
    done < "$d/.tool-versions"
  fi

  # Ruby
  if [[ -f "$d/.ruby-version" ]]; then
    _rt_add ruby "$(_clean_ver "$(cat "$d/.ruby-version")")"
  elif [[ -f "$d/Gemfile" ]]; then
    local rv; rv="$(grep -E '^[[:space:]]*ruby[[:space:]]+["'\'']' "$d/Gemfile" 2>/dev/null | head -1 | sed -E 's/.*["'\'']([0-9][0-9.]*).*/\1/')"
    [[ -n "$rv" ]] && _rt_add ruby "$rv" || _rt_add ruby latest
  fi

  # Node — only pin if the project asks for a specific version (else base Node is used).
  if [[ -f "$d/.nvmrc" ]]; then
    _rt_add node "$(_clean_ver "$(cat "$d/.nvmrc")")"
  elif [[ -f "$d/package.json" ]]; then
    local nv; nv="$(grep -oE '"node"[[:space:]]*:[[:space:]]*"[^"]+"' "$d/package.json" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)"$/\1/' | grep -oE '[0-9][0-9.]*' | head -1)"
    [[ -n "$nv" ]] && _rt_add node "$nv"
  fi

  # Python
  if [[ -f "$d/.python-version" ]]; then
    _rt_add python "$(_clean_ver "$(cat "$d/.python-version")")"
  elif [[ -f "$d/runtime.txt" ]] && grep -qiE 'python-[0-9]' "$d/runtime.txt"; then
    _rt_add python "$(grep -oiE 'python-[0-9][0-9.]*' "$d/runtime.txt" | head -1 | sed 's/[Pp]ython-//')"
  elif [[ -f "$d/pyproject.toml" || -f "$d/requirements.txt" || -f "$d/setup.py" ]]; then
    _rt_add python 3.12
  fi

  # Go
  if [[ -f "$d/go.mod" ]]; then
    local gv; gv="$(grep -E '^go[[:space:]]+[0-9]' "$d/go.mod" 2>/dev/null | head -1 | awk '{print $2}')"
    [[ -n "$gv" ]] && _rt_add go "$gv" || _rt_add go latest
  fi

  # Rust
  if [[ -f "$d/rust-toolchain.toml" ]]; then
    _rt_add rust "$(grep -E '^channel' "$d/rust-toolchain.toml" 2>/dev/null | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
  elif [[ -f "$d/rust-toolchain" ]]; then
    _rt_add rust "$(_clean_ver "$(cat "$d/rust-toolchain")")"
  elif [[ -f "$d/Cargo.toml" ]]; then
    _rt_add rust latest
  fi

  printf '%s' "$RT"
}

detect_install() {
  local d="$1"

  [[ -f "$d/Gemfile" ]] && echo 'echo "→ bundle install"; bundle install'

  if [[ -f "$d/package.json" ]]; then
    if   [[ -f "$d/yarn.lock"      ]]; then echo 'corepack enable >/dev/null 2>&1 || true; echo "→ yarn install"; yarn install'
    elif [[ -f "$d/pnpm-lock.yaml" ]]; then echo 'corepack enable >/dev/null 2>&1 || true; echo "→ pnpm install"; pnpm install'
    elif [[ -f "$d/package-lock.json" ]]; then echo 'echo "→ npm ci"; npm ci'
    else echo 'echo "→ npm install"; npm install'
    fi
  fi

  if [[ -f "$d/pyproject.toml" ]]; then
    if   [[ -f "$d/poetry.lock" ]]; then echo 'pip install -q poetry >/dev/null 2>&1 || true; echo "→ poetry install"; poetry install'
    elif [[ -f "$d/uv.lock"     ]]; then echo 'pip install -q uv >/dev/null 2>&1 || true; echo "→ uv sync"; uv sync'
    else echo 'echo "→ pip install ."; pip install -e . 2>/dev/null || pip install .'
    fi
  elif [[ -f "$d/requirements.txt" ]]; then
    echo 'echo "→ pip install -r requirements.txt"; pip install -r requirements.txt'
  fi

  [[ -f "$d/go.mod"    ]] && echo 'echo "→ go mod download"; go mod download'
  [[ -f "$d/Cargo.toml" ]] && echo 'echo "→ cargo fetch"; cargo fetch'

  return 0
}
