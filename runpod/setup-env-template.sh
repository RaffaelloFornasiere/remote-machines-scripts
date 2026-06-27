#!/bin/bash
# RunPod Environment Setup Script
# Runs from the start command (best-effort). For LLM dev + interpretability work.
# Non-fatal by design: never use `set -e` here, or one failing extra blocks the pod.
set -uo pipefail

export HOME="${HOME:-/root}"
export PATH="$HOME/.local/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive

log() { echo "[setup] $*"; }

# Directory of this script and the bootstrap repo root (this file lives in <repo>/runpod/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Single apt-get update for the whole script (start command already ran one,
# but this script may run much later, so refresh once here).
log "Updating package lists..."
apt-get update

log "Installing core tools..."
apt-get install -y \
    tmux \
    vim \
    htop \
    nvtop \
    git-lfs \
    jq \
    ripgrep \
    ncdu \
    tree \
    fd-find \
    bat \
    curl \
    wget \
    build-essential \
    fish

# git-lfs
git lfs install || log "WARN: git lfs install failed"

# ---------------------------------------------------------------------------
# uv (Python package manager)
# ---------------------------------------------------------------------------
log "Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh || log "WARN: uv install failed"
export PATH="$HOME/.local/bin:$PATH"

# ---------------------------------------------------------------------------
# Node.js + latest npm + CLIs (codex, claude)
# ---------------------------------------------------------------------------
log "Installing Node.js..."
timeout 120 bash -lc "curl -fsSL https://deb.nodesource.com/setup_current.x | bash" \
  && log "NodeSource repo configured" \
  || log "WARN: NodeSource setup skipped/failed/timed out"
timeout 120 bash -lc "apt-get install -y nodejs" \
  && log "nodejs installed" \
  || log "WARN: nodejs install skipped/failed/timed out"
timeout 180 bash -lc "npm install -g npm@latest" \
  && log "npm updated to latest" \
  || log "WARN: npm update skipped/failed/timed out"
timeout 180 bash -lc "npm i -g @openai/codex" \
  && log "@openai/codex installed" \
  || log "WARN: codex install skipped/failed/timed out"

# Claude CLI (installed exactly once, here)
timeout 60 bash -lc "curl -fsSL https://claude.ai/install.sh | bash" \
  && log "Claude installed" \
  || log "WARN: Claude install skipped/failed/timed out"

# ---------------------------------------------------------------------------
# tmux config
# ---------------------------------------------------------------------------
log "Writing tmux config..."
cat > ~/.tmux.conf << 'EOF'
# Enable mouse support
set -g mouse on
# Better scrollback
set -g history-limit 50000
# Start windows and panes at 1, not 0
set -g base-index 1
setw -g pane-base-index 1
# Easier split commands
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
# Reload config with r
bind r source-file ~/.tmux.conf \; display "Config reloaded!"
# Better colors
set -g default-terminal "screen-256color"
# Reduce escape time (better for vim)
set -sg escape-time 10
# Enable focus events
set-option -g focus-events on
EOF

# ---------------------------------------------------------------------------
# Shell profile (shared by fish + bash)
# ---------------------------------------------------------------------------
log "Writing fish profile..."
cat > ~/.runpod_profile.fish << 'EOF'
# Runpod Profile - sourced by fish config
fish_add_path $HOME/.local/bin
# Git aliases
alias gits='git status'
alias gitb='git branch'
alias gitl='git log --graph --oneline'
alias gd='git diff'
# System aliases
alias ll='ls -lah'
alias nv='nvtop'
alias top='htop'
alias gpus='nvidia-smi'
alias usage='ncdu'
alias fd='fdfind'
alias cat='batcat --paging=never'
alias bat='batcat'
alias ..='cd ..'
alias ...='cd ../..'
function fish_greeting
    echo "Runpod environment ready"
    echo "Python: "(python3 --version 2>/dev/null || echo "not found")
    echo "uv: "(uv --version 2>/dev/null || echo "not found")
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "No GPU detected"
end
EOF

log "Writing fish config..."
mkdir -p ~/.config/fish
cat > ~/.config/fish/config.fish << 'EOF'
# Load environment variables from /proc/1/environ (RunPod injects vars there)
if test -r /proc/1/environ
    for line in (cat /proc/1/environ | tr '\0' '\n')
        if string match -qr '^[A-Za-z_][A-Za-z0-9_]*=.*' -- $line
            set -l varname (string split -m1 '=' $line)[1]
            if test "$varname" != PATH
                set -gx $varname (string split -m1 '=' $line)[2]
            end
        end
    end
end
if test -f ~/.runpod_profile.fish
    source ~/.runpod_profile.fish
end
EOF

log "Updating bash profile (fallback)..."
cat >> ~/.bashrc << 'EOF'
# Runpod environment
export PATH="$HOME/.local/bin:$PATH"
alias gits='git status'
alias gitb='git branch'
alias gitl='git log --graph --oneline'
alias gd='git diff'
alias ll='ls -lah'
alias nv='nvtop'
alias gpus='nvidia-smi'
alias usage='ncdu'
alias fd='fdfind'
alias bat='batcat'
# Start fish only for interactive shells (Remote-SSH uses non-interactive)
if [[ $- == *i* ]] && command -v fish >/dev/null 2>&1; then
  exec fish
fi
EOF

# ---------------------------------------------------------------------------
# vim config
# ---------------------------------------------------------------------------
log "Writing vim config..."
cat > ~/.vimrc << 'EOF'
set number
set relativenumber
set mouse=a
set expandtab
set tabstop=4
set shiftwidth=4
set autoindent
set smartindent
set hlsearch
set incsearch
set ignorecase
set smartcase
set clipboard=unnamedplus
syntax on
set background=dark
set cursorline
set scrolloff=8
set signcolumn=yes
set updatetime=300
set encoding=utf-8
EOF

# ---------------------------------------------------------------------------
# Global Claude Code config (~/.claude/CLAUDE.md)
# Copied from the bootstrap repo so every machine shares one source of truth.
# ---------------------------------------------------------------------------
log "Installing global CLAUDE.md..."
if [ -f "$REPO_ROOT/CLAUDE.md" ]; then
  mkdir -p ~/.claude
  cp "$REPO_ROOT/CLAUDE.md" ~/.claude/CLAUDE.md \
    && log "Global CLAUDE.md installed to ~/.claude/CLAUDE.md" \
    || log "WARN: failed to copy CLAUDE.md"
else
  log "WARN: CLAUDE.md not found at $REPO_ROOT/CLAUDE.md, skipping"
fi

# ---------------------------------------------------------------------------
# Clone the working repo (parameterized via env vars)
#   CLONE_REPO_SSH : SSH url of the repo to clone (e.g. git@github.com:you/repo.git)
#   CLONE_REPO_DIR : optional target dir (default: /root/<repo-name>)
#   CLONE_REPO_REF : optional branch/tag to check out
# ---------------------------------------------------------------------------
if [ -n "${CLONE_REPO_SSH:-}" ]; then
  reponame="$(basename "${CLONE_REPO_SSH%.git}")"
  target="${CLONE_REPO_DIR:-/root/$reponame}"
  log "Cloning $CLONE_REPO_SSH -> $target"
  rm -rf "$target"
  timeout 300 git clone --recurse-submodules \
    ${CLONE_REPO_REF:+--branch "$CLONE_REPO_REF"} \
    "$CLONE_REPO_SSH" "$target" \
    && log "Repo cloned (SSH)" \
    || log "WARN: Repo clone skipped/failed/timed out"
else
  log "CLONE_REPO_SSH not set, skipping repo clone"
fi

log "=== Setup complete ==="
