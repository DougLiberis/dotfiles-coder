# dotfiles-coder

Linux-only dotfiles for [Coder](https://github.com/LiberisFinance/coder-workspaces)
engineer workspaces. Deliberately minimal: **no chezmoi, no OS switches, no
local-terminal config** (ghostty/wezterm), no GPG/signing or credential helpers
(Coder manages `gh` auth). Everything is driven by a single `install.sh`.

The full, multi-OS dotfiles managed with chezmoi live in
[`DougLiberis/dotfiles`](https://github.com/DougLiberis/dotfiles); this repo is
the Coder-only subset.

## Usage

Set the **Dotfiles URI** parameter on your workspace to this repo's HTTPS URL:

```
https://github.com/DougLiberis/dotfiles-coder
```

Coder clones the **default branch** and runs `install.sh` at the repo root on
every workspace start and on the **Refresh Dotfiles** button.

> Coder only ever clones the default branch — there is no branch selector — so
> this is a standalone repo rather than a branch of the chezmoi repo.

## What `install.sh` does

| Area | Action |
|---|---|
| tmux | Copies `tmux.conf` → `~/.tmux.conf`; clones TPM + catppuccin; installs plugins (resurrect, continuum, sensible) |
| neovim | Merge-copies `config/nvim/` → `~/.config/nvim/` (LazyVim); headless `Lazy! sync` if `nvim` is present |
| git | Copies `gitconfig` → `~/.config/git/dotfiles-coder.gitconfig` and wires it in via an **additive** `include.path` (never overwrites `~/.gitconfig`) |
| bash | Idempotent, interactivity-guarded append to `~/.bashrc` to auto-attach to a persistent tmux `main` session |

The script **assumes `tmux` and `nvim` are already installed** in the workspace
image — it places config and bootstraps plugins only (no binary installs, no
`sudo`). If a tool is missing, its config is still placed and the step is
skipped cleanly.

## Constraints honoured

`install.sh` runs **after** the workspace entrypoint and is idempotent. It only
touches entrypoint-managed files additively:

- `~/.bashrc` — guarded append only (`grep -q` before `>>`).
- `~/.gitconfig` — never written directly; settings come via `include.path`.
- `~/.npmrc`, `~/.config/gh/`, `~/.claude/settings.json` — not touched.

If `install.sh` ever breaks your shell, blank the **Dotfiles URI** parameter,
restart, fix the script, then set the URI back and use **Refresh Dotfiles**.

## Recovery / re-apply

Use the **Refresh Dotfiles** button on the workspace page to re-pull and
re-apply without a restart.
