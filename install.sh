#!/usr/bin/env bash
#
# Coder workspace dotfiles installer (Linux-only).
#
# Runs on every workspace start and on the "Refresh Dotfiles" button, AFTER the
# workspace entrypoint. Must be idempotent: running twice must not duplicate
# entries or corrupt config.
#
# Assumes tmux and neovim already exist in the workspace image — this script
# only places config and bootstraps plugins (no binary installs, no sudo).
#
# Protected files (managed by entrypoint.sh) are touched ADDITIVELY only:
#   ~/.bashrc                guarded append (never overwrite)
#   ~/.npmrc, ~/.config/gh/, ~/.claude/settings.json   not touched here
# See https://github.com/LiberisFinance/coder-workspaces/blob/main/docs/dotfiles.md
#
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[dotfiles] %s\n' "$*"; }

# ---------- tmux ----------
log "Placing tmux config"
cp "$DOTFILES_DIR/tmux.conf" "$HOME/.tmux.conf"

if command -v git >/dev/null 2>&1; then
  if [ ! -d "$HOME/.tmux/plugins/tpm" ]; then
    log "Cloning TPM"
    git clone --depth=1 https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
  fi
  catppuccin_dir="$HOME/.config/tmux/plugins/catppuccin/tmux"
  if [ ! -d "$catppuccin_dir" ]; then
    log "Cloning catppuccin/tmux"
    mkdir -p "$(dirname "$catppuccin_dir")"
    git clone --depth=1 https://github.com/catppuccin/tmux "$catppuccin_dir"
  fi
  if command -v tmux >/dev/null 2>&1; then
    log "Installing tmux plugins via TPM"
    "$HOME/.tmux/plugins/tpm/bin/install_plugins" || log "TPM install_plugins returned non-zero (continuing)"
  else
    log "tmux not on PATH — skipping plugin install"
  fi
fi

# ---------- neovim / LazyVim ----------
log "Placing neovim config"
mkdir -p "$HOME/.config/nvim"
# Merge-copy (trailing /.) so LazyVim's generated lazy-lock.json and plugin
# state on the persistent home volume survive across boots.
cp -R "$DOTFILES_DIR/config/nvim/." "$HOME/.config/nvim/"

if command -v nvim >/dev/null 2>&1; then
  log "Syncing LazyVim plugins (headless)"
  nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1 || log "Lazy sync returned non-zero (continuing)"
else
  log "nvim not on PATH — config placed; plugins will sync on first launch"
fi

# ---------- git ----------
# Use an additive include so we never clobber the entrypoint-managed ~/.gitconfig
# (credential helpers, gh auth, proxy settings).
log "Configuring git via additive include"
mkdir -p "$HOME/.config/git"
cp "$DOTFILES_DIR/gitconfig" "$HOME/.config/git/dotfiles-coder.gitconfig"
include_target="$HOME/.config/git/dotfiles-coder.gitconfig"
if ! git config --global --get-all include.path 2>/dev/null | grep -qxF "$include_target"; then
  git config --global --add include.path "$include_target"
fi

# ---------- bashrc: auto-attach to tmux ----------
# Append-only with idempotency guard. The inline interactivity check ($-) keeps
# non-interactive shells (agents, scripts) from being hijacked into tmux.
if ! grep -q 'tmux new-session -A -s main' "$HOME/.bashrc" 2>/dev/null; then
  log "Adding tmux auto-attach to ~/.bashrc"
  cat >> "$HOME/.bashrc" <<'BASHRC'

# Auto-attach to (or create) a persistent tmux session named 'main' for
# interactive shells only.
if [[ $- == *i* ]] && [ -z "$TMUX" ] && command -v tmux >/dev/null 2>&1; then
  exec tmux new-session -A -s main
fi
BASHRC
fi

log "Done."
