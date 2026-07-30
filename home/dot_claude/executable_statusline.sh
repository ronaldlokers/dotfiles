#!/bin/bash
# Claude Code statusline: model | dir | branch + git state | context used.
# Needs a Nerd Font and a truecolor terminal.
input=$(cat)

c() { printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"; }
RESET=$'\033[0m'
C_MODEL=$(c 34 211 238)     # cyan
C_DIR=$(c 148 163 184)      # slate
C_BRANCH=$(c 167 139 250)   # violet
C_DIRTY=$(c 251 191 36)     # amber
C_SYNC=$(c 56 189 248)      # sky
C_OK=$(c 74 222 128)        # green
C_WARN=$(c 251 191 36)      # amber
C_CRIT=$(c 248 113 113)     # red
SEP="   "                   # between groups; within a group a single space

IFS=$'\t' read -r model dir pct < <(
  jq -r '[.model.display_name // "?",
          .workspace.current_dir // ".",
          .context_window.remaining_percentage // ""] | @tsv' <<<"$input"
)

out="${C_MODEL}󰚩 ${model}${RESET}${SEP}${C_DIR}󰉋 ${dir##*/}${RESET}"

# one git call covers branch, ahead/behind and the dirty count
IFS=$'\t' read -r branch dirty ahead behind < <(
  git -C "$dir" status --porcelain=v2 --branch 2>/dev/null | awk '
    $1=="#" && $2=="branch.head" { b=$3 }
    $1=="#" && $2=="branch.ab"   { a=$3+0; be=-($4+0) }
    $1!="#"                      { d++ }
    END { if (b!="") printf "%s\t%d\t%d\t%d\n", b, d, a, be }'
)
if [ -n "$branch" ]; then
  out+="${SEP}${C_BRANCH}󰘬 ${branch}${RESET}"
  [ "${dirty:-0}" -gt 0 ]  && out+=" ${C_DIRTY}󰏫 ${dirty}${RESET}"
  [ "${ahead:-0}" -gt 0 ]  && out+=" ${C_SYNC}󰜷${ahead}${RESET}"
  [ "${behind:-0}" -gt 0 ] && out+=" ${C_SYNC}󰜮${behind}${RESET}"
fi

if [ -n "$pct" ]; then
  p=${pct%.*}
  # a bare fraction like ".5" strips to empty, which would make the integer
  # comparisons below error out ("integer expression expected"); treat any
  # non-integer as 0% remaining (worst case, so it shows red).
  case "$p" in ''|*[!0-9]*) p=0 ;; esac
  # report context *used*, so the bar fills up as the window is consumed
  used=$(( 100 - p ))
  if [ "$used" -ge 80 ]; then col=$C_CRIT
  elif [ "$used" -ge 60 ]; then col=$C_WARN
  else col=$C_OK
  fi
  cells=8
  filled=$(( (used * cells + 50) / 100 ))
  bar=""
  for ((i = 0; i < cells; i++)); do
    if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
  done
  out+="${SEP}${col}󰧑 ${bar} ${used}%${RESET}"
fi

printf '%s' "$out"
