# Portable zsh entry point for the AgentOS workstation.
export PATH="$HOME/.local/bin:$PATH"
export EDITOR=nvim
export VISUAL=nvim

if command -v chromium >/dev/null 2>&1; then
  export AGENT_BROWSER_EXECUTABLE_PATH="$(command -v chromium)"
  export PLAYWRIGHT_MCP_EXECUTABLE_PATH="$AGENT_BROWSER_EXECUTABLE_PATH"
fi

# User-scoped generated completions, including Herdr.
fpath=("$HOME/.zfunc" $fpath)
autoload -Uz compinit
compinit -i

[[ -r "$HOME/.zsh/shell.zsh" ]] && source "$HOME/.zsh/shell.zsh"
[[ -r "$HOME/.zsh/aliases.zsh" ]] && source "$HOME/.zsh/aliases.zsh"

command -v starship >/dev/null && eval "$(starship init zsh)"
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"
command -v atuin >/dev/null && eval "$(atuin init zsh)"
command -v fnm >/dev/null && eval "$(fnm env --use-on-cd)"
[[ -r /usr/share/fzf/key-bindings.zsh ]] && source /usr/share/fzf/key-bindings.zsh
[[ -r /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
