# runpod-bootstrap

Shared startup config for my RunPod pods. One source of truth for the start command and environment setup.

## How it works

1. The **start command** (set in the RunPod template) does only what must run as PID 1: SSHD, GitHub SSH key, git identity.
2. It then clones this repo (`BOOTSTRAP_REPO`) and runs `setup-env-template.sh`.
3. `setup-env-template.sh` installs all tooling, writes shell/editor configs, and clones the working repo for the pod.

```
start command  ──clones──>  this repo  ──runs──>  setup-env-template.sh  ──clones──>  working repo
```

## Files

| File | Purpose |
|------|---------|
| `start-command.sh` | Paste contents into the RunPod template's start command field. |
| `setup-env-template.sh` | Non-blocking environment setup (Node, uv, claude/codex, tmux/vim/fish, repo clone). |
| `CLAUDE.md` | Global Claude Code instructions; copied to `~/.claude/CLAUDE.md` on every machine by the setup script. |

## Environment variables

Set these in the RunPod template (Environment Variables).

**Required**

| Var | Description |
|-----|-------------|
| `BASE_64_SSH_PRIVATE_KEY` | base64-encoded GitHub SSH private key. |
| `BOOTSTRAP_REPO` | SSH url of this repo. |
| `CLONE_REPO_SSH` | SSH url of the working repo to clone on the pod. |

**Optional**

| Var | Default | Description |
|-----|---------|-------------|
| `SSH_PUBLIC_KEY` | — | Authorized key for root login (if not relying on RunPod injection). |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | — | Git commit identity. |
| `BOOTSTRAP_REF` | `main` | Branch/tag of this repo to use. |
| `BOOTSTRAP_SCRIPT` | `setup-env-template.sh` | Setup script path within this repo. |
| `CLONE_REPO_DIR` | `/root/<repo-name>` | Where to clone the working repo. |
| `CLONE_REPO_REF` | — | Branch/tag of the working repo. |

## Setup

Encode your private key:

```bash
base64 -w0 ~/.ssh/id_ed25519
```

Paste the output into `BASE_64_SSH_PRIVATE_KEY`, paste `start-command.sh` into the start command field, set the vars above, and launch.

## Notes

- The setup script is best-effort: a failing optional install won't block the pod, and SSH comes up first so you can always get in.
- Logs: `/var/log/pod_startup.log`.
