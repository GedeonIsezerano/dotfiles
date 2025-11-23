#!/bin/bash
set -e

echo "🚀 Setting up your Mac..."

# Install Homebrew if not present
if ! command -v brew &> /dev/null; then
    echo "📦 Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH for Apple Silicon
    if [[ $(uname -m) == "arm64" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
fi

# Install packages from Brewfile
echo "📦 Installing packages from Brewfile..."
brew bundle install --file=~/.dotfiles/Brewfile

# Install Claude Code
echo "🤖 Installing Claude Code..."
npm install -g @anthropic-ai/claude-code

# Create symlinks
echo "🔗 Creating symlinks..."

# Zsh config
ln -sf ~/.dotfiles/zsh/.zshrc ~/.zshrc

# Git config
ln -sf ~/.dotfiles/git/.gitconfig ~/.gitconfig

# Neovim config
mkdir -p ~/.config
ln -sf ~/.dotfiles/nvim ~/.config/nvim

echo "✅ Setup complete! Restart your terminal."
