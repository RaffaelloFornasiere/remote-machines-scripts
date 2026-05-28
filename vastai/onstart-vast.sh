#!/bin/bash
# Vast.ai onstart script.
# Use with SSH launch mode: Vast already runs sshd and injects your login key,
# so we do NOT configure or start sshd here.
# Paste into the "On-start Script" field, or save as /root/onstart.sh.

exec > >(tee -a /var/log/pod_startup.log) 2>&1
set -uo pipefail
echo "=== Vast onstart: $(date -Is) ==="

export HOME=/root
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.ssh" /root/bootstrap
chmod 700 "$HOME/.ssh"

# Disable Vast's auto-tmux (otherwise every SSH/VS Code terminal shares one session)
touch /root/.no_auto_tmux

# --- Make env vars visible to future SSH/tmux sessions ---
# Vast strips your -e vars from SSH sessions; persist them so later shells see them.
env | grep -vE '^(PWD|SHLVL|_|HOME|PATH)=' >> /etc/environment
echo "export PATH=\"$HOME/.local/bin:\$PATH\"" > /etc/profile.d/99-local-bin.sh

apt-get update
apt-get install -y curl git ca-certificates openssh-client

# --- GitHub SSH private key (needed before any clone) ---
if [ -n "${BASE_64_SSH_PRIVATE_KEY:-}" ]; then
  umask 077
  printf "%s" "$BASE_64_SSH_PRIVATE_KEY" | tr -d "\r" | base64 -d > /root/.ssh/id_ed25519
  chmod 600 /root/.ssh/id_ed25519
  cat > /root/.ssh/config << "EOF"
Host github.com
  HostName github.com
  User git
  IdentityFile /root/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  chmod 600 /root/.ssh/config
  echo "INFO: SSH key configured for GitHub"
else
  echo "INFO: BASE_64_SSH_PRIVATE_KEY not set, skipping GitHub SSH key setup"
fi

# --- Git identity ---
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
  echo "INFO: Git email configured as $GIT_USER_EMAIL"
fi
if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --global user.name "$GIT_USER_NAME"
  echo "INFO: Git name configured as $GIT_USER_NAME"
fi

# --- Pull shared bootstrap repo and run the setup script (same one as RunPod) ---
# BOOTSTRAP_REPO  : SSH url of the repo holding the setup script
# BOOTSTRAP_REF   : optional branch/tag (default: main)
# BOOTSTRAP_SCRIPT: optional path within repo (default: setup-env-template.sh)
if [ -n "${BOOTSTRAP_REPO:-}" ]; then
  rm -rf /root/bootstrap/repo
  timeout 120 git clone --depth 1 ${BOOTSTRAP_REF:+--branch "$BOOTSTRAP_REF"} "$BOOTSTRAP_REPO" /root/bootstrap/repo \
    && echo "INFO: Bootstrap repo cloned" \
    || echo "WARN: Bootstrap repo clone skipped/failed/timed out"
  SCRIPT_PATH="/root/bootstrap/repo/${BOOTSTRAP_SCRIPT:-setup-env-template.sh}"
  if [ -f "$SCRIPT_PATH" ]; then
    timeout 600 bash "$SCRIPT_PATH" \
      && echo "INFO: Bootstrap setup complete" \
      || echo "WARN: Bootstrap setup failed/timed out"
  else
    echo "WARN: Bootstrap script not found at $SCRIPT_PATH"
  fi
else
  echo "INFO: BOOTSTRAP_REPO not set, skipping bootstrap setup"
fi

echo "=== Vast onstart done ==="
# Note: no `sleep infinity` — Vast keeps the container alive itself.