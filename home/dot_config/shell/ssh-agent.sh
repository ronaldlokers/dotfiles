# shellcheck shell=sh
# Keep SSH_AUTH_SOCK pointing at a live agent, then make sure it holds keys.
#
# Forwarded sockets die with their connection but the socket file lingers, so
# probe with ssh-add rather than testing -S: it exits 2 only when no agent
# answers. Sourced by dot_zshrc and dot_bashrc.
_agent_live() {
  [ -S "${1:-}" ] || return 1
  SSH_AUTH_SOCK="$1" ssh-add -l > /dev/null 2>&1
  [ "$?" -ne 2 ]
}
_agent_link="$HOME/.ssh/agent.sock"
if ! _agent_live "${SSH_AUTH_SOCK:-}"; then
  # word-splitting the find output into candidate sockets is intentional
  # shellcheck disable=SC2046
  for _s in "$_agent_link" \
      $(command find /tmp -maxdepth 2 -path '/tmp/auth-agent*' -name listener.sock -type s 2> /dev/null | xargs -r ls -t 2> /dev/null) \
      "${XDG_RUNTIME_DIR:-/nonexistent}/ssh-agent.socket"; do
    if _agent_live "$_s"; then
      export SSH_AUTH_SOCK="$_s"
      break
    fi
  done
  unset _s
fi
# Republish at a stable path so long-lived shells recover after a reconnect.
if [ "${SSH_AUTH_SOCK:-}" != "$_agent_link" ] && _agent_live "${SSH_AUTH_SOCK:-}"; then
  mkdir -p "$HOME/.ssh"
  ln -sf "$SSH_AUTH_SOCK" "$_agent_link"
  export SSH_AUTH_SOCK="$_agent_link"
fi
unset _agent_link

# Keys live in Proton Pass, not on disk. `ssh-add -l` exits 1 for "no
# identities" and 2 for "no agent", so this fires only on a live empty agent.
if _agent_live "${SSH_AUTH_SOCK:-}" &&
  ! SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh-add -l > /dev/null 2>&1 &&
  command -v proton-ssh-load > /dev/null 2>&1; then
  proton-ssh-load --quiet
fi
unset -f _agent_live
