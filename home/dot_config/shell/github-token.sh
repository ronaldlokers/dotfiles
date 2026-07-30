# shellcheck shell=sh
# Publish gh's token as GITHUB_PERSONAL_ACCESS_TOKEN, which the GitHub MCP
# server authenticates with. Sourced by dot_zshrc and dot_bashrc.
if command -v gh > /dev/null 2>&1; then
  # An empty value produces the same malformed header as no value, so only
  # export a token that exists.
  _gh_token="$(gh auth token 2> /dev/null || true)"
  if [ -n "$_gh_token" ]; then
    export GITHUB_PERSONAL_ACCESS_TOKEN="$_gh_token"
  fi
  unset _gh_token
fi
