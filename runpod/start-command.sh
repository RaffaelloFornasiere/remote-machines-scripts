bash -lc 'exec > >(tee -a /var/log/pod_startup.log) 2>&1
set -euo pipefail
echo "=== Pod startup: $(date -Is) ==="

export HOME=/root
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.ssh" /run/sshd /root/bootstrap
chmod 700 "$HOME/.ssh"

# Ensure ~/.local/bin on PATH for all future shells
cat > /etc/profile.d/99-local-bin.sh << "EOF"
export PATH="$HOME/.local/bin:$PATH"
EOF

apt-get update
apt-get install -y curl git ca-certificates openssh-client openssh-server

# --- Start SSHD early so the pod is always reachable, even if later steps fail ---
ssh-keygen -A
cat > /etc/ssh/sshd_config.d/custom.conf << "EOF"
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
EOF
/usr/sbin/sshd
echo "INFO: SSH daemon started"

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

# --- Optional: root login key (independent of RunPod injection) ---
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
  echo "$SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  echo "INFO: SSH public key configured for server access"
else
  echo "INFO: SSH_PUBLIC_KEY not set (relying on RunPod key injection, if any)"
fi

# --- Git identity (needed before clone/commits) ---
if [ -n "${GIT_USER_EMAIL:-}" ]; then
  git config --global user.email "$GIT_USER_EMAIL"
  echo "INFO: Git email configured as $GIT_USER_EMAIL"
fi
if [ -n "${GIT_USER_NAME:-}" ]; then
  git config --global user.name "$GIT_USER_NAME"
  echo "INFO: Git name configured as $GIT_USER_NAME"
fi

# --- Best-effort everything-else lives in the bootstrap setup script ---
# It is pulled from a repo so all your pods share one source of truth.
# BOOTSTRAP_REPO  : SSH url of the repo holding setup-env-template.sh (your shared configs)
# BOOTSTRAP_REF   : optional branch/tag (default: main)
# BOOTSTRAP_SCRIPT: optional path within repo (default: setup-env-template.sh)
set +e
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
set -e

sleep infinity
'
