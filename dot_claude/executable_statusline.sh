#!/bin/bash
# Claude Code statusline: model | dir | branch | context left | cost, plus
# the caveman mode badge when active.
input=$(cat)

model=$(jq -r '.model.display_name // "?"' <<<"$input")
dir=$(jq -r '.workspace.current_dir // "?"' <<<"$input")
pct=$(jq -r '.context_window.remaining_percentage // empty' <<<"$input")
cost=$(jq -r '.cost.total_cost_usd // empty' <<<"$input")

branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)

out="\033[36m${model}\033[0m \033[2m${dir##*/}\033[0m"
[ -n "$branch" ] && out+=" \033[35m${branch}\033[0m"
if [ -n "$pct" ]; then
  p=${pct%.*}
  # a bare fraction like ".5" strips to empty, which would make the integer
  # comparisons below error out ("integer expression expected"); treat any
  # non-integer as 0% remaining (worst case, so it shows red).
  case "$p" in ''|*[!0-9]*) p=0 ;; esac
  if [ "$p" -le 20 ]; then c=31; elif [ "$p" -le 40 ]; then c=33; else c=32; fi
  out+=" \033[${c}mctx ${p}%\033[0m"
fi
[ -n "$cost" ] && out+=$(printf ' \033[2m$%.2f\033[0m' "$cost")

# caveman badge (renders nothing when mode is off)
caveman=$(ls -td "$HOME"/.claude/plugins/cache/caveman/caveman/*/src/hooks/caveman-statusline.sh 2>/dev/null | head -1)
[ -n "$caveman" ] && out+=" $(bash "$caveman" </dev/null)"

printf '%b' "$out"
