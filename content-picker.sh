#!/bin/sh
# Fuzzy-ish search over the visible terminal content of open herdr agents.
# One row per agent, ranked by hits. Enter jumps to the agent.
H="${HERDR_BIN_PATH:-herdr}"
SELF="$0"
TAB="$(printf '\t')"

for dep in jq fzf awk; do
  command -v "$dep" >/dev/null 2>&1 || { echo "content-picker: missing dependency '$dep'" >&2; exit 1; }
done

# Line matches when it contains every query word (case-insensitive).
HITS_AWK='
  BEGIN { n = split(tolower(q), w, " ") }
  { l = tolower($0); ok = n > 0; for (i = 1; i <= n; i++) if (!index(l, w[i])) ok = 0 }
'

snapshot() {
  "$H" agent list | jq -r '.result.agents[] | select(.focused | not)
    | [.pane_id, .tab_id, .workspace_id, .agent, .agent_status,
       ((.display_agent // .terminal_title_stripped // .agent) | gsub("\""; "")),
       (.foreground_cwd // .cwd), (.agent_session.value // "")] | @tsv' > "$D/agents"
  # Reads cost ~6ms per line, so cap lines and read all panes in parallel.
  cut -f1 "$D/agents" | {
    while read -r pane; do
      "$H" pane read "$pane" --source recent-unwrapped --lines 500 > "$D/$pane" &
    done
    wait
  }
  ws=$("$H" workspace list)
  while IFS="$TAB" read -r pane tab wsid kind status label cwd session; do
    wsl=$(printf '%s' "$ws" | jq -r --arg id "$wsid" '.result.workspaces[] | select(.workspace_id == $id) | .label')
    mtime=0; [ -f "$session" ] && mtime=$(stat -f %m "$session" 2>/dev/null || stat -c %Y "$session" 2>/dev/null)
    mtime=${mtime:-0}
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pane" "$tab" "$kind" "$status" "$label" "$wsl" "$mtime"
  done < "$D/agents" > "$D/meta"
}

rows() {
  now=$(date +%s)
  while IFS="$TAB" read -r pane tab kind status label wsl mtime; do
    hits=$(awk -v q="$1" "$HITS_AWK"' ok { c++ } END { print c + 0 }' "$D/$pane")
    [ -n "$1" ] && [ "$hits" -eq 0 ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$hits" "$pane" "$tab" "$kind" "$status" "$label" "$wsl" "$mtime"
  done < "$D/meta" |
  sort -t "$TAB" -k1,1nr |
  awk -F "$TAB" -v now="$now" '
    function age(t) { if (!t) return "-"; s = now - t
      return s < 60 ? s "s" : s < 3600 ? int(s/60) "m" : s < 86400 ? int(s/3600) "h" : int(s/86400) "d" }
    BEGIN { col["blocked"] = 31; col["working"] = 33; col["idle"] = 32; col["done"] = 32 }
    { c = ($5 in col) ? col[$5] : 90
      printf "%s\t%s\t\033[%sm● %-8s\033[0m %5s  %-38.38s %-18.18s %-7s %5s\n",
        $2, $3, c, $5, ($1 ? $1 : "·"), $6, $7, $4, age($8) }'
}

preview() {
  IFS="$TAB" read -r _ _ kind status label wsl _ <<EOF
$(grep "^$1$TAB" "$D/meta")
EOF
  cwd=$(grep "^$1$TAB" "$D/agents" | cut -f7)
  printf '\033[1m%s\033[0m  %s · %s · %s\n%s\n\n' "$label" "$kind" "$status" "$wsl" "$cwd"
  if [ -z "$2" ]; then tail -40 "$D/$1"; exit; fi
  # Each hit with 2 lines of context, '--' between groups, query words highlighted.
  awk -v q="$2" "$HITS_AWK"'
    function hl(s,   out, l, i, k, p, best, bl) {
      out = ""
      while (1) { l = tolower(s); best = 0
        for (k = 1; k <= n; k++) if ((p = index(l, w[k])) && (!best || p < best)) { best = p; bl = length(w[k]) }
        if (!best) return out s
        out = out substr(s, 1, best - 1) "\033[1;30;43m" substr(s, best, bl) "\033[0m"; s = substr(s, best + bl) } }
    { line[NR] = $0; hit[NR] = ok }
    END { last = 0
      for (i = 1; i <= NR; i++) if (hit[i]) for (j = i - 2; j <= i + 2; j++) if (j > last && j >= 1 && j <= NR) {
        if (last && j > last + 1) print "\033[90m──\033[0m"
        printf "\033[90m%4d│\033[0m %s\n", j, hl(line[j]); last = j } }' "$D/$1"
}

case "$1" in
  --load) D="$2"; snapshot; rows ""; exit ;;
  --rows) D="$2"; rows "$3"; exit ;;
  --preview) D="$2"; preview "$3" "$4"; exit ;;
esac

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
header=$(printf '%-10s %5s  %-38s %-18s %-7s %5s' STATUS HITS AGENT WORKSPACE KIND ACTIVE)
sel=$(: | fzf --ansi --disabled --delimiter="$TAB" --with-nth=3.. --reverse \
  --prompt='search> ' --header="$header" --header-first \
  --bind "start:reload:'$SELF' --load '$D'" \
  --bind "change:reload:'$SELF' --rows '$D' {q}" \
  --preview "'$SELF' --preview '$D' {1} {q}" --preview-window=down,60%,wrap) || exit 0

"$H" tab focus "$(printf '%s' "$sel" | cut -f2)" >/dev/null
"$H" agent focus "$(printf '%s' "$sel" | cut -f1)" >/dev/null 2>&1 || true
