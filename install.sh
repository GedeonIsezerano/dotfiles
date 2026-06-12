#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
export PATH="$PNPM_HOME:$PNPM_HOME/bin:$HOME/.local/bin:$PATH"

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

have() {
    command -v "$1" >/dev/null 2>&1
}

backup_if_needed() {
    local target="$1"

    if [ -L "$target" ] || [ ! -e "$target" ]; then
        return
    fi

    local backup="${target}.backup.$(date +%Y%m%d%H%M%S)"
    log "Backing up $target to $backup"
    mv "$target" "$backup"
}

link_file() {
    local source="$1"
    local target="$2"

    mkdir -p "$(dirname "$target")"
    backup_if_needed "$target"
    ln -sfn "$source" "$target"
}

install_ubuntu_packages() {
    local packages=(zsh neovim nodejs ripgrep fd-find fzf curl)

    if ! have apt-get; then
        warn "apt-get not found; skipping Ubuntu package installation."
        return
    fi

    if sudo -n true 2>/dev/null; then
        log "Installing Ubuntu packages..."
        sudo apt-get update
        sudo apt-get install -y "${packages[@]}"
    else
        warn "sudo requires a password; skipping apt packages: ${packages[*]}"
    fi
}

install_git() {
    if have git; then
        return
    fi

    case "$OS" in
        Darwin)
            install_homebrew_packages
            ;;
        Linux)
            if have apt-get && sudo -n true 2>/dev/null; then
                log "Installing git..."
                sudo apt-get update
                sudo apt-get install -y git
            elif have brew; then
                log "Installing git..."
                brew install git
            else
                warn "git is required but could not be installed without sudo or Homebrew."
            fi
            ;;
        *)
            warn "git is required but automatic installation is not configured for $OS."
            ;;
    esac
}

install_neovim_release() {
    if have nvim || [ "$OS" != "Linux" ]; then
        return
    fi

    local machine
    machine="$(uname -m)"

    if [ "$machine" != "x86_64" ]; then
        warn "No user-local Neovim fallback configured for $machine."
        return
    fi

    if ! have curl || ! have tar; then
        warn "curl and tar are required for the user-local Neovim fallback."
        return
    fi

    local archive
    archive="$(mktemp)"
    local install_dir="$HOME/.local/opt/nvim-linux-x86_64"

    log "Installing Neovim release to $install_dir..."
    curl -fL \
        "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz" \
        -o "$archive"
    rm -rf "$install_dir"
    mkdir -p "$HOME/.local/opt"
    tar -xzf "$archive" -C "$HOME/.local/opt"
    rm -f "$archive"

    mkdir -p "$HOME/.local/bin"
    ln -sfn "$install_dir/bin/nvim" "$HOME/.local/bin/nvim"
}

install_tree_sitter_cli() {
    if have tree-sitter; then
        return
    fi

    local os_name machine asset
    os_name="$(uname -s)"
    machine="$(uname -m)"

    case "$os_name:$machine" in
        Linux:x86_64) asset="tree-sitter-cli-linux-x64.zip" ;;
        Linux:aarch64 | Linux:arm64) asset="tree-sitter-cli-linux-arm64.zip" ;;
        Darwin:x86_64) asset="tree-sitter-cli-macos-x64.zip" ;;
        Darwin:arm64) asset="tree-sitter-cli-macos-arm64.zip" ;;
        *)
            warn "No user-local tree-sitter CLI fallback configured for $os_name/$machine."
            return
            ;;
    esac

    if ! have curl || ! have unzip; then
        warn "curl and unzip are required for the user-local tree-sitter CLI fallback."
        return
    fi

    local archive
    archive="$(mktemp)"

    log "Installing tree-sitter CLI..."
    curl -fL "https://github.com/tree-sitter/tree-sitter/releases/latest/download/$asset" -o "$archive"
    mkdir -p "$HOME/.local/bin"
    unzip -p "$archive" tree-sitter > "$HOME/.local/bin/tree-sitter"
    chmod +x "$HOME/.local/bin/tree-sitter"
    rm -f "$archive"
}

ensure_fd_command() {
    if have fd || ! have fdfind; then
        return
    fi

    mkdir -p "$HOME/.local/bin"
    ln -sfn "$(command -v fdfind)" "$HOME/.local/bin/fd"
}

install_homebrew_packages() {
    if ! have brew; then
        log "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        if [ -x /opt/homebrew/bin/brew ]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
            eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
        fi
    fi

    log "Installing packages from Brewfile..."
    brew bundle install --file="$DOTFILES_DIR/Brewfile"
}

clone_or_update() {
    local repo="$1"
    local dest="$2"

    if [ -d "$dest/.git" ]; then
        log "Updating $dest"
        git -C "$dest" pull --ff-only
    elif [ ! -e "$dest" ]; then
        log "Cloning $repo"
        git clone --depth=1 "$repo" "$dest"
    else
        warn "$dest exists but is not a git checkout; leaving it unchanged."
    fi
}

install_shell_extras() {
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        log "Installing Oh My Zsh..."
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
            "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    else
        log "Oh My Zsh already installed."
    fi

    local custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    clone_or_update "https://github.com/zsh-users/zsh-autosuggestions.git" \
        "$custom/plugins/zsh-autosuggestions"
    clone_or_update "https://github.com/zsh-users/zsh-syntax-highlighting.git" \
        "$custom/plugins/zsh-syntax-highlighting"
    clone_or_update "https://github.com/romkatv/powerlevel10k.git" \
        "$custom/themes/powerlevel10k"
}

install_pnpm() {
    if have pnpm; then
        return
    fi

    mkdir -p "$PNPM_HOME"

    if have brew; then
        log "Installing pnpm..."
        brew install pnpm
        return
    fi

    if have corepack; then
        log "Enabling pnpm with corepack..."
        corepack enable
        corepack prepare pnpm@latest --activate
        return
    fi

    if have curl; then
        log "Installing pnpm..."
        SHELL="${SHELL:-/bin/sh}" curl -fsSL https://get.pnpm.io/install.sh | sh -
        export PATH="$PNPM_HOME:$PNPM_HOME/bin:$PATH"
        return
    fi

    warn "pnpm could not be installed because curl is unavailable."
}

install_codex() {
    install_pnpm

    if have pnpm; then
        log "Installing Codex..."
        pnpm add -g @openai/codex
    else
        warn "pnpm not found; skipping Codex installation."
    fi
}

log "Setting up dotfiles from $DOTFILES_DIR"

case "$OS" in
    Linux)
        if [ -r /etc/os-release ] && grep -qi ubuntu /etc/os-release; then
            install_ubuntu_packages
        elif have brew; then
            install_homebrew_packages
        else
            warn "Unsupported Linux distribution; skipping package installation."
        fi
        ;;
    Darwin)
        install_homebrew_packages
        ;;
    *)
        warn "Unsupported OS: $OS; skipping package installation."
        ;;
esac

install_git
install_shell_extras
install_codex
install_neovim_release
install_tree_sitter_cli
ensure_fd_command

log "Creating symlinks..."
link_file "$DOTFILES_DIR/zsh/.zshrc" "$HOME/.zshrc"
link_file "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
link_file "$DOTFILES_DIR/nvim" "$HOME/.config/nvim"

log "Setup complete. Restart your terminal."
