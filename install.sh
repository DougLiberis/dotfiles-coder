#!/usr/bin/env bash
#
# Coder workspace dotfiles installer (Linux-only).
#
# Runs on every workspace start and on the "Refresh Dotfiles" button, AFTER the
# workspace entrypoint. Must be idempotent: running twice must not duplicate
# entries or corrupt config.
#
# Assumes tmux already exists in the workspace image. neovim is installed into
# ~/.local if missing (no sudo); this script otherwise only places config and
# bootstraps plugins.
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

# ---------- neovim binary (no root) ----------
# The workspace image is expected to ship neovim, but not all images do. If it's
# missing, install a prebuilt release into ~/.local (persistent home volume, on
# PATH) so the headless plugin sync below can run. No sudo.
if ! command -v nvim >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/nvim" ]; then
  case "$(uname -m)" in
    x86_64)  nvim_asset="nvim-linux-x86_64.tar.gz" ;;
    aarch64) nvim_asset="nvim-linux-arm64.tar.gz" ;;
    *)       nvim_asset=""; log "unsupported arch $(uname -m) — skipping nvim install" ;;
  esac
  if [ -n "$nvim_asset" ]; then
    log "neovim not found — installing $nvim_asset into ~/.local"
    nvim_tmp="$(mktemp -d)"
    if curl -fsSL -o "$nvim_tmp/nvim.tar.gz" \
        "https://github.com/neovim/neovim/releases/download/stable/$nvim_asset"; then
      mkdir -p "$HOME/.local"
      tar -xzf "$nvim_tmp/nvim.tar.gz" -C "$HOME/.local" --strip-components=1 \
        && log "neovim installed to ~/.local" \
        || log "neovim extract failed — continuing"
    else
      log "neovim download failed — continuing"
    fi
    rm -rf "$nvim_tmp"
  fi
fi

# ---------- neovim / LazyVim ----------
log "Placing neovim config"
mkdir -p "$HOME/.config/nvim"
# Merge-copy (trailing /.) so LazyVim's generated lazy-lock.json and plugin
# state on the persistent home volume survive across boots.
cp -R "$DOTFILES_DIR/config/nvim/." "$HOME/.config/nvim/"

# Resolve nvim even if ~/.local/bin isn't on PATH yet (fresh non-login shell).
nvim_bin="$(command -v nvim 2>/dev/null || true)"
[ -z "$nvim_bin" ] && [ -x "$HOME/.local/bin/nvim" ] && nvim_bin="$HOME/.local/bin/nvim"

if [ -n "$nvim_bin" ]; then
  log "Syncing LazyVim plugins (headless)"
  "$nvim_bin" --headless "+Lazy! sync" +qa >/dev/null 2>&1 || log "Lazy sync returned non-zero (continuing)"
else
  log "nvim not available — config placed; plugins will sync on first launch"
fi

# ---------- git ----------
# IDENTITY: the workspace entrypoint sets a DEFAULT BOT identity before dotfiles
# run (liberis-ai-engineer[bot] in PAT mode, or the GitHub App login in App
# mode). Dotfiles run AFTER the entrypoint, so setting these directly overrides
# the bot — commits are then authored as you. (`git config` replaces existing
# values, so this is safe to run unconditionally.)
log "Setting git identity (overrides entrypoint bot identity)"
git config --global user.name  "Doug Finnie"
git config --global user.email "doug.finnie@liberis.com"

# AUTH is deliberately NOT touched here. The entrypoint owns the credential
# helper / url.insteadOf proxy routing that authenticates pushes — leave it be.
#
# Other preferences (editor, aliases) come via an additive include so we never
# rewrite the entrypoint-managed ~/.gitconfig wholesale.
log "Applying git preferences via additive include"
mkdir -p "$HOME/.config/git"
cp "$DOTFILES_DIR/gitconfig" "$HOME/.config/git/dotfiles-coder.gitconfig"
include_target="$HOME/.config/git/dotfiles-coder.gitconfig"
if ! git config --global --get-all include.path 2>/dev/null | grep -qxF "$include_target"; then
  git config --global --add include.path "$include_target"
fi

# ---------- login shells: ensure ~/.bashrc is sourced ----------
# `coder ssh` (and SSH generally) start a LOGIN shell, which sources
# ~/.bash_profile | ~/.bash_login | ~/.profile — but NOT ~/.bashrc. Without one
# of those chaining to ~/.bashrc, the tmux auto-attach below never runs on
# connect (you land at a bare prompt and `tmux a` reports "no sessions"). Create
# a minimal ~/.bash_profile only if no login-shell entry point already exists.
if [ ! -f "$HOME/.bash_profile" ] && [ ! -f "$HOME/.bash_login" ] && [ ! -f "$HOME/.profile" ]; then
  log "Creating ~/.bash_profile to source ~/.bashrc for login shells"
  cat > "$HOME/.bash_profile" <<'PROFILE'
# Login shells source this, not ~/.bashrc. Chain to ~/.bashrc so interactive
# login shells (e.g. `coder ssh`) get the same setup, including tmux auto-attach.
[ -f ~/.bashrc ] && . ~/.bashrc
PROFILE
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
