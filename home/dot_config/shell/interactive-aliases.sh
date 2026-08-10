# shellcheck shell=sh
# Shared interactive aliases for Bash and Zsh.
# Keep shell-specific widgets in the rc files; this file is the one source of
# truth for commands and aliases both shells should expose.
if command -v nvim > /dev/null ; then
  alias v="nvim"
fi

if command -v git > /dev/null ; then
  alias gp="git pull"
fi

if command -v lazygit > /dev/null ; then
  alias lg="lazygit"
fi

if command -v kubectl > /dev/null ; then
  alias k="kubectl"
fi

if command -v bat > /dev/null ; then
  alias cat="bat"
fi

if command -v lsd > /dev/null ; then
  alias ls="lsd"
  alias ll="ls -lgh"
  alias la='ls -lathr'
  alias lla='ls -lgha'
  alias lt='ls --tree'
  alias tree='ls --tree'
fi

if command -v dust > /dev/null ; then
  alias du="dust"
fi

if command -v duf > /dev/null ; then
  alias df="duf"
fi

if command -v btop > /dev/null ; then
  alias top="btop"
fi
