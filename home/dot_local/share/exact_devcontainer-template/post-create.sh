#!/usr/bin/env bash
set -euo pipefail

# Everything the project pins lives in its own mise.toml — same source of truth
# as host-side work, so the container can't drift from it. Trust first, otherwise
# the install prompts and there is no TTY to answer on.
mise trust --quiet
mise install --yes

# Project-specific setup goes below: dependency installs, browser downloads,
# whatever the repo needs. Keep it idempotent — post-create runs again whenever
# the container is rebuilt.
