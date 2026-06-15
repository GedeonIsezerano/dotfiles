#!/usr/bin/env bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
export PATH="$PNPM_HOME:$PNPM_HOME/bin:$HOME/.local/opt/go/bin:$HOME/.local/bin:$PATH"

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

have() {
    command -v "$1" >/dev/null 2>&1
}

version_at_least() {
    local actual="$1"
    local minimum="$2"

    awk -v actual="$actual" -v minimum="$minimum" '
        BEGIN {
            split(actual, a, ".")
            split(minimum, m, ".")
            for (i = 1; i <= 3; i++) {
                av = a[i] + 0
                mv = m[i] + 0
                if (av > mv) exit 0
                if (av < mv) exit 1
            }
            exit 0
        }
    '
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
    local packages=(
        zsh
        neovim
        git
        nodejs
        npm
        golang-go
        ripgrep
        fd-find
        fzf
        curl
        tar
        unzip
        ca-certificates
    )

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
    local minimum_version="0.11.0"

    if [ "$OS" != "Linux" ]; then
        if have nvim; then
            local current_version
            current_version="$(nvim --version | sed -n '1s/^NVIM v\([0-9.]*\).*/\1/p')"
            if [ -n "$current_version" ] && version_at_least "$current_version" "$minimum_version"; then
                return
            fi
        fi
        warn "Neovim $minimum_version or newer is required, but automatic release installation is only configured for Linux."
        return
    fi

    if have nvim; then
        local current_version
        current_version="$(nvim --version | sed -n '1s/^NVIM v\([0-9.]*\).*/\1/p')"
        if [ -z "$current_version" ] || ! version_at_least "$current_version" "$minimum_version"; then
            warn "Neovim $minimum_version or newer is required; installing a user-local release."
        else
            log "Updating user-local Neovim release..."
        fi
    else
        log "Installing user-local Neovim release..."
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
    trap 'rm -f "$archive"; trap - RETURN' RETURN
    local install_dir="$HOME/.local/opt/nvim-linux-x86_64"

    curl -fL \
        "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz" \
        -o "$archive"
    rm -rf "$install_dir"
    mkdir -p "$HOME/.local/opt"
    tar -xzf "$archive" -C "$HOME/.local/opt"

    mkdir -p "$HOME/.local/bin"
    ln -sfn "$install_dir/bin/nvim" "$HOME/.local/bin/nvim"
}

go_version() {
    go version 2>/dev/null | awk '{ print $3 }' | sed 's/^go//'
}

install_go_release() {
    local minimum_version="1.21.0"

    if [ "$OS" != "Linux" ]; then
        local current_version
        current_version="$(go_version || true)"
        if [ -n "$current_version" ] && version_at_least "$current_version" "$minimum_version"; then
            return
        fi
        warn "Go $minimum_version or newer is required for gopls, but automatic release installation is only configured for Linux."
        return
    fi

    local machine arch
    machine="$(uname -m)"

    case "$machine" in
        x86_64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        *)
            warn "No user-local Go fallback configured for $machine."
            return
            ;;
    esac

    if ! have curl || ! have tar; then
        warn "curl and tar are required for the user-local Go fallback."
        return
    fi

    local version latest_version archive install_root
    version="$(curl -fsSL "https://go.dev/dl/?mode=json" | sed -n 's/.*"version": "\(go[0-9.]*\)".*/\1/p' | head -n 1)"
    if [ -z "$version" ]; then
        warn "Could not determine the latest Go release."
        return
    fi
    latest_version="${version#go}"

    if have go; then
        local current_version
        current_version="$(go_version || true)"
        if [ -n "$current_version" ] && version_at_least "$current_version" "$latest_version"; then
            return
        fi

        if [ -z "$current_version" ] || ! version_at_least "$current_version" "$minimum_version"; then
            warn "Go $minimum_version or newer is required for gopls; installing $version."
        else
            log "Updating Go from $current_version to $latest_version..."
        fi
    else
        log "Installing $version..."
    fi

    archive="$(mktemp)"
    trap 'rm -f "$archive"; trap - RETURN' RETURN
    install_root="$HOME/.local/opt"

    log "Installing $version to $install_root/go..."
    curl -fL "https://go.dev/dl/${version}.linux-${arch}.tar.gz" -o "$archive"
    rm -rf "$install_root/go"
    mkdir -p "$install_root"
    tar -xzf "$archive" -C "$install_root"
    export PATH="$install_root/go/bin:$PATH"
}

install_tree_sitter_cli() {
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
    trap 'rm -f "$archive"; trap - RETURN' RETURN

    if have tree-sitter; then
        log "Updating tree-sitter CLI..."
    else
        log "Installing tree-sitter CLI..."
    fi
    curl -fL "https://github.com/tree-sitter/tree-sitter/releases/latest/download/$asset" -o "$archive"
    mkdir -p "$HOME/.local/bin"
    unzip -p "$archive" tree-sitter > "$HOME/.local/bin/tree-sitter"
    chmod +x "$HOME/.local/bin/tree-sitter"
}

ensure_fd_command() {
    if have fd || ! have fdfind; then
        return
    fi

    mkdir -p "$HOME/.local/bin"
    ln -sfn "$(command -v fdfind)" "$HOME/.local/bin/fd"
}

install_ripgrep() {
    if have brew; then
        log "Installing or upgrading ripgrep..."
        brew upgrade ripgrep 2>/dev/null || brew install ripgrep
        return
    fi

    if have apt-get && sudo -n true 2>/dev/null; then
        log "Installing or upgrading ripgrep..."
        sudo apt-get update
        sudo apt-get install -y ripgrep
        return
    fi

    if have cargo; then
        log "Installing or upgrading ripgrep with cargo..."
        cargo install ripgrep --locked
        return
    fi

    local rg_path
    rg_path="$(command -v rg 2>/dev/null || true)"

    case "$rg_path" in
        "$HOME/.local/bin/rg" | "$HOME/.cargo/bin/rg" | /usr/bin/rg | /usr/local/bin/rg | /opt/homebrew/bin/rg | /home/linuxbrew/.linuxbrew/bin/rg)
            return
            ;;
        *"/codex-path/rg")
            mkdir -p "$HOME/.local/bin"
            ln -sfn "$rg_path" "$HOME/.local/bin/rg"
            return
            ;;
        "")
            ;;
        *)
            return
            ;;
    esac

    local codex_rg
    codex_rg="$(find "$PNPM_HOME" "$HOME/.local/share/pnpm" -path '*/codex-path/rg' -type f -perm -111 2>/dev/null | sort | tail -n 1 || true)"

    if [ -n "$codex_rg" ]; then
        mkdir -p "$HOME/.local/bin"
        ln -sfn "$codex_rg" "$HOME/.local/bin/rg"
        return
    fi

    warn "ripgrep is required for Telescope live_grep but could not be installed."
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

    log "Updating Homebrew metadata..."
    brew update
    log "Installing and upgrading packages from Brewfile..."
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
    elif [ -d "$HOME/.oh-my-zsh/.git" ]; then
        log "Updating Oh My Zsh..."
        git -C "$HOME/.oh-my-zsh" pull --ff-only
    else
        warn "$HOME/.oh-my-zsh exists but is not a git checkout; leaving it unchanged."
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
        if ! have brew && have corepack; then
            log "Updating pnpm with corepack..."
            corepack prepare pnpm@latest --activate
        fi
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

install_uv() {
    if have brew; then
        log "Installing or upgrading uv..."
        brew upgrade uv 2>/dev/null || brew install uv
        return
    fi

    if have uv; then
        log "Updating uv..."
        if uv self update; then
            return
        fi

        if have curl; then
            warn "uv self-update failed; installing the latest standalone uv instead."
            curl -LsSf https://astral.sh/uv/install.sh | sh
            return
        fi

        warn "uv self-update failed and curl is unavailable."
        return
    fi

    if have curl; then
        log "Installing uv..."
        curl -LsSf https://astral.sh/uv/install.sh | sh
        return
    fi

    warn "uv could not be installed because curl is unavailable."
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
install_uv
install_codex
install_neovim_release
install_go_release
install_tree_sitter_cli
install_ripgrep
ensure_fd_command

log "Creating symlinks..."
link_file "$DOTFILES_DIR/zsh/.zshrc" "$HOME/.zshrc"
link_file "$DOTFILES_DIR/git/.gitconfig" "$HOME/.gitconfig"
link_file "$DOTFILES_DIR/nvim" "$HOME/.config/nvim"

log "Setup complete. Restart your terminal."
