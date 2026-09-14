# Linux dotfiles layer

This directory contains the portable subset of the workstation configuration:
zsh, Kitty, Starship, Atuin, and Git. It intentionally excludes secrets, SSH
keys, AGTERM, macOS paths, launch agents, and the separate macOS Kitty tree.

`install-dotfiles` links these files into the workstation user's home directory.
Neovim integration is opt-in. Set `INSTALL_NVIM=1` and provide
`AGENTOS_DOTFILES_REPO` (or `DOTFILES_REPO`) to clone a repository containing
the Neovim configuration; the default install only links the bundled files.

The Neovim wrapper loads a Linux overlay that replaces its macOS-only file
actions with `xdg-open` and clipboard-safe path commands.
