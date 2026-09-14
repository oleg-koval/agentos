#!/usr/bin/env bash
# Compact, memorable command/hotkey reference for this workstation.
set -euo pipefail

cat <<'EOF'
AGENTOS CHEATSHEET
==================
Think: AgentOS Home is the shell. Meta/Super controls the shell. F8 is the
remote-safe fallback when an RDP client does not forward the Meta key.

AGENTOS HOME
------------
  DO                         KEY                         MEMORY
  Command palette            Super/Meta + K              K = command
  Command palette fallback   F8                          works over stubborn RDP
  Terminal                   Super/Meta + Enter          open work
  Home                       Super/Meta + H              H = home
  Workspace view             Super/Meta + 1              first surface
  Agents view                Super/Meta + 2              second surface
  Activity view              Super/Meta + 3              third surface
  System view                Super/Meta + 4              fourth surface

  Inside Home only:
  Workspace / Agents /
  Activity / System          Alt + 1 / 2 / 3 / 4         RDP-safe view fallback

  On macOS RDP, Command normally maps to Linux Meta/Super. If it does not,
  switch Windows App keyboard mode to Scancode and use F8 as the guaranteed
  palette fallback.

I3 FALLBACK SESSION
-------------------
  Terminal                   Super + Enter
  App launcher               Super + D
  Close window               Super + Shift + Q
  Fullscreen                 Super + F

  Focus left/down/up/right   Super + H/J/K/L
  Move window                Super + Shift + H/J/K/L
  Workspace 1..10            Super + 1..0
  Move to workspace 1..10    Super + Shift + 1..0
  Reload i3 config           Super + Shift + C
  Restart i3                 Super + Shift + R
  Exit i3                    Super + Shift + E

HERDR
-----
  Launch / reattach          herdr
  Prefix                     Ctrl + B                    B = boss key
  Detach                     Ctrl+B, then Q
  New tab                    Ctrl+B, then C
  Next / previous tab        Ctrl+B, then N / P
  Tab 1..9                   Ctrl+B, then 1..9
  Vertical split             Ctrl+B, then V
  Horizontal split           Ctrl+B, then -
  Close pane                 Ctrl+B, then X
  Zoom pane                  Ctrl+B, then Z
  Navigate panes             Ctrl+B, then H/J/K/L
  Help                       Ctrl+B, then ?

PROJECTS
--------
  csrc                       cd ~/src          canonical repositories
  cwt                        cd ~/worktrees    agent/parallel worktrees
  cscratch                   cd ~/scratch      disposable experiments
  cbuild                     cd ~/build        generated build output

WORKSTATION
-----------
  sync-workstation           converge/update this machine
  agentos state              canonical state from agentosd
  agentos health             health from agentosd
  workstation-doctor         health check (sudo for full hardware checks)
  rollback-workstation list  list recovery snapshots (sudo)
  hermes                     Hermes CLI
  claude                     Claude Code
  codex                      Codex
  herdr                      persistent agent workspace

RULE OF THUMB
-------------
  AgentOS Home = one shell surface
  Super/Meta   = global shell controls
  F8           = palette when RDP eats Meta
  Alt+1..4     = view fallback inside Home
  Ctrl+B       = Herdr prefix

Run `cheatsheet` whenever you forget.
EOF
