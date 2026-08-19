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

# ---------- shell utilities: fzf, zoxide, tree, eza, bat ----------
# No sudo. fzf/zoxide/tree: `apt-get download` fetches the .deb without
# installing (only needs the already-populated system apt index, not root),
# then `dpkg-deb -x` extracts its contents straight onto the persistent home
# volume. eza/bat use static musl release binaries instead (see below).
# Idempotent: each install is skipped once its binary is already on PATH or
# in ~/.local/bin.
NAV_TOOLS_STAGE="$HOME/.local/share/dotfiles-coder/nav-tools"
install_apt_binary() {
  pkg="$1"; bin="$2"
  command -v "$bin" >/dev/null 2>&1 && return 0
  [ -x "$HOME/.local/bin/$bin" ] && return 0
  if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-deb >/dev/null 2>&1; then
    log "apt-get/dpkg-deb not found — skipping $pkg"
    return 0
  fi
  log "Installing $pkg (no-sudo: apt-get download + dpkg-deb -x)"
  tmp="$(mktemp -d)"
  if (cd "$tmp" && apt-get download "$pkg") >/dev/null 2>&1; then
    mkdir -p "$NAV_TOOLS_STAGE" "$HOME/.local/bin" "$HOME/.local/share/bash-completion/completions"
    dpkg-deb -x "$tmp/${pkg}"_*.deb "$NAV_TOOLS_STAGE" 2>/dev/null || log "$pkg extract failed (continuing)"
    find "$NAV_TOOLS_STAGE/usr/bin" -maxdepth 1 -type f -exec cp -f {} "$HOME/.local/bin/" \; 2>/dev/null || true
    if [ -f "$NAV_TOOLS_STAGE/usr/share/bash-completion/completions/$bin" ]; then
      cp -f "$NAV_TOOLS_STAGE/usr/share/bash-completion/completions/$bin" "$HOME/.local/share/bash-completion/completions/" 2>/dev/null || true
    fi
  else
    log "$pkg download failed (continuing, likely offline)"
  fi
  rm -rf "$tmp" "$NAV_TOOLS_STAGE"
}
install_apt_binary fzf fzf
install_apt_binary zoxide zoxide
install_apt_binary tree tree

# eza/bat: the Ubuntu .deb builds are dynamically linked against libgit2 (and
# its own transitive deps), which the base image doesn't ship — chasing that
# chain without apt-get install is fragile. Upstream publishes statically
# linked musl release binaries with zero shared-lib dependencies instead, so
# fetch those directly (same no-sudo, ~/.local/bin approach as the nvim
# install above).
install_github_musl_binary() {
  repo="$1"; asset_pattern="$2"; bin_in_tarball="$3"; target_bin="$4"
  command -v "$target_bin" >/dev/null 2>&1 && return 0
  [ -x "$HOME/.local/bin/$target_bin" ] && return 0
  if ! command -v curl >/dev/null 2>&1; then
    log "curl not found — skipping $target_bin"
    return 0
  fi
  log "Installing $target_bin from $repo (static musl release, no-sudo)"
  url="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*"' \
    | grep -F "$asset_pattern" \
    | head -1 \
    | sed -E 's/.*"(https[^"]+)".*/\1/')"
  if [ -z "$url" ]; then
    log "$target_bin: no matching release asset found (continuing)"
    return 0
  fi
  tmp="$(mktemp -d)"
  if curl -fsSL -o "$tmp/asset.tar.gz" "$url" && tar -xzf "$tmp/asset.tar.gz" -C "$tmp" 2>/dev/null; then
    found="$(find "$tmp" -type f -name "$bin_in_tarball" | head -1)"
    if [ -n "$found" ]; then
      mkdir -p "$HOME/.local/bin"
      cp "$found" "$HOME/.local/bin/$target_bin"
      chmod +x "$HOME/.local/bin/$target_bin"
    else
      log "$target_bin: binary not found in downloaded archive (continuing)"
    fi
  else
    log "$target_bin: download/extract failed (continuing, likely offline)"
  fi
  rm -rf "$tmp"
}

case "$(uname -m)" in
  x86_64)  gh_musl_arch="x86_64" ;;
  aarch64) gh_musl_arch="aarch64" ;;
  *)       gh_musl_arch="" ;;
esac
if [ -n "$gh_musl_arch" ]; then
  install_github_musl_binary "eza-community/eza" "${gh_musl_arch}-unknown-linux-musl.tar.gz" eza eza
  install_github_musl_binary "sharkdp/bat" "${gh_musl_arch}-unknown-linux-musl.tar.gz" bat bat
else
  log "unsupported arch $(uname -m) — skipping eza/bat"
fi

# fzf's Ctrl-T/Ctrl-R/Alt-C key bindings ship only as a doc example in the
# Ubuntu package (no dedicated shell-init file like zoxide/eza), so stash a
# stable copy under ~/.local/share for ~/.bashrc to source.
if command -v fzf >/dev/null 2>&1 || [ -x "$HOME/.local/bin/fzf" ]; then
  fzf_kb_src="/usr/share/doc/fzf/examples/key-bindings.bash"
  fzf_kb_dst="$HOME/.local/share/dotfiles-coder/fzf-key-bindings.bash"
  if [ -f "$fzf_kb_src" ] && [ ! -f "$fzf_kb_dst" ]; then
    mkdir -p "$(dirname "$fzf_kb_dst")"
    cp "$fzf_kb_src" "$fzf_kb_dst"
  fi
fi

# ---------- bashrc: path-navigation aliases + fzf/zoxide init ----------
if ! grep -q 'dotfiles-coder: nav aliases' "$HOME/.bashrc" 2>/dev/null; then
  log "Adding path-navigation aliases + fzf/zoxide init to ~/.bashrc"
  cat >> "$HOME/.bashrc" <<'BASHRC'

# dotfiles-coder: nav aliases (ls shortcuts, dir-stack, fzf, zoxide, eza, bat)
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
command -v eza >/dev/null 2>&1 && alias lt='eza --tree --icons --group-directories-first'
[ -f "$HOME/.local/share/dotfiles-coder/fzf-key-bindings.bash" ] && . "$HOME/.local/share/dotfiles-coder/fzf-key-bindings.bash"
[ -f "$HOME/.local/share/bash-completion/completions/fzf" ] && . "$HOME/.local/share/bash-completion/completions/fzf"
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init bash)"
BASHRC
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

# ---------- claude: design-council skill ----------
# The design-council plugin is vendored here (rather than installed via a
# Claude Code plugin marketplace) because the workspace's plugin-marketplace
# registry (~/.claude/plugins/known_marketplaces.json and the
# extraKnownMarketplaces block in ~/.claude/settings.json) gets reset on every
# workspace boot by something upstream of dotfiles — even marketplaces pinned
# via extraKnownMarketplaces do not survive. Skills placed under
# ~/.claude/skills/ are auto-loaded every session with no marketplace/registry
# involved at all, and are unaffected by that reset. Merge-copy (trailing /.)
# so this stays in sync with the vendored copy without disturbing anything a
# future `claude plugin update`-equivalent might place alongside it.
log "Syncing design-council Claude skill"
mkdir -p "$HOME/.claude/skills/design-council"
cp -R "$DOTFILES_DIR/claude-skills/design-council/." "$HOME/.claude/skills/design-council/"

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

# ---------- ssh commit signing ----------
# Sign every commit with a per-workspace SSH key so it's verifiable that the
# commit was made from this workspace. The PRIVATE key is generated locally and
# NEVER committed to the dotfiles repo (it lives only in ~/.ssh on the
# persistent home volume). Register the PUBLIC key with GitHub as a *Signing
# Key* (Settings -> SSH and GPG keys -> New SSH key -> type "Signing Key") to
# get the "Verified" badge on GitHub.
#
# Idempotent: the key is only generated when absent, so it survives reboots and
# is regenerated only if the home volume is recreated.
SIGNING_KEY="$HOME/.ssh/id_ed25519_signing"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$SIGNING_KEY" ]; then
  log "Generating SSH commit-signing key ($SIGNING_KEY)"
  ssh-keygen -t ed25519 -N "" \
    -C "doug.finnie@liberis.com (coder workspace signing key)" \
    -f "$SIGNING_KEY" >/dev/null
fi
# Unconditional, outside the generation guard: if the home volume is ever
# restored/synced from elsewhere (backup, migration, chezmoi re-apply) the key
# can land with a looser mode picked up from that process's umask. OpenSSH
# refuses to load a group/world-readable private key, so re-assert 600 on
# every run rather than only at generation time.
chmod 600 "$SIGNING_KEY"

# Tell git to sign with the SSH key (gpg.format=ssh, no GPG involved) and to
# sign commits and tags by default. Set directly so the absolute key path is
# resolved against this user's $HOME.
log "Configuring git SSH commit signing"
git config --global gpg.format ssh
git config --global user.signingkey "$SIGNING_KEY.pub"
git config --global commit.gpgsign true
git config --global tag.gpgsign true

# allowed_signers lets local `git log --show-signature` / `git verify-commit`
# confirm the signature instead of reporting "no principal matched".
allowed_signers="$HOME/.ssh/allowed_signers"
printf '%s %s\n' "doug.finnie@liberis.com" "$(cat "$SIGNING_KEY.pub")" > "$allowed_signers"
git config --global gpg.ssh.allowedSignersFile "$allowed_signers"

log "Commit-signing public key (register on GitHub as a Signing Key):"
cat "$SIGNING_KEY.pub"

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
