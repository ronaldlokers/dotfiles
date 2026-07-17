# shellcheck shell=sh
# Keep SSH_AUTH_SOCK pointing at a *live* agent. Forwarded sockets
# (devpod/ssh -A) die when their connection closes but the socket file
# lingers, so -S alone can't spot a stale one: probe with ssh-add, which
# exits 2 only when no agent answers. If the current socket is dead, fall
# back to the stable symlink, then any live devpod-forwarded socket, then
# the systemd user ssh-agent (dot_config/systemd/user).
#
# Sourced by both dot_zshrc and dot_bashrc — it runs in the calling shell,
# so each keeps its own word-splitting semantics exactly as when this was
# inlined in the two rc files.
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
# republish the live agent at the stable path so long-lived shells
# (tmux panes, resurrected sessions) can recover it after a reconnect
if [ "${SSH_AUTH_SOCK:-}" != "$_agent_link" ] && _agent_live "${SSH_AUTH_SOCK:-}"; then
  mkdir -p "$HOME/.ssh"
  ln -sf "$SSH_AUTH_SOCK" "$_agent_link"
  export SSH_AUTH_SOCK="$_agent_link"
fi
unset _agent_link
unset -f _agent_live
