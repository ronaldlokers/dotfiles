# shellcheck shell=sh
# Publish gh's token as GITHUB_PERSONAL_ACCESS_TOKEN.
#
# The GitHub MCP server the claude-code github plugin points at
# (https://api.githubcopilot.com/mcp/) authenticates with a personal access
# token read from this variable — it sends `Authorization: Bearer
# ${GITHUB_PERSONAL_ACCESS_TOKEN}` and has no OAuth flow at all. With the
# variable unset the header expands to a bare `Bearer `, which the server
# rejects with `400 bad request: Authorization header is badly formatted` —
# an error that reads like a broken connection rather than a missing
# credential, which is what makes it worth a comment this long.
#
# The token comes from `gh`, whose hosts.yml is already an age blob in this
# repo, so this introduces no second copy of the secret and nothing new to
# rotate.
#
# Scope note: this exports into the shell environment, so every process
# started from an interactive shell inherits a token carrying `repo` and
# `workflow`. That is a deliberate choice for convenience over blast radius
# — scoping it to the claude process alone (a wrapper function) is the
# tighter alternative if that trade stops being worth it.
#
# Sourced by both dot_zshrc and dot_bashrc.
if command -v gh > /dev/null 2>&1; then
  # Never export an empty value: on a fresh machine gh exists before it is
  # authenticated, and an empty token produces exactly the same malformed
  # header as no token at all, only harder to spot.
  _gh_token="$(gh auth token 2> /dev/null || true)"
  if [ -n "$_gh_token" ]; then
    export GITHUB_PERSONAL_ACCESS_TOKEN="$_gh_token"
  fi
  unset _gh_token
fi
