if [[ -n "${KITTY_WINDOW_ID:-}" && -z "${TMUX:-}" ]]; then
  tmux attach-session -t main 2>/dev/null || tmux new-session -s main
fi
