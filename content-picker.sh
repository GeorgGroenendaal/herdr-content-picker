#!/bin/sh
# Search open herdr agents' terminal content plus past pi/Claude sessions.
# Live agents rank first, past sessions after. Enter jumps to the agent or
# resumes the session in a new tab.
H="${HERDR_BIN_PATH:-herdr}"
SELF="$0"
TAB="$(printf '\t')"
PI_SESSIONS="${PI_SESSIONS:-$HOME/.pi/agent/sessions}"
CLAUDE_SESSIONS="${CLAUDE_SESSIONS:-$HOME/.claude/projects}"
HISTORY_LIMIT=50
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/herdr-content-picker"
set -f  # query words like * must stay literal

for dep in jq fzf awk rg; do
  command -v "$dep" >/dev/null 2>&1 || { echo "content-picker: missing dependency '$dep'" >&2; exit 1; }
done

# Shared awk: a line matches when it contains every query word (case-insensitive);
# hl() highlights the words.
AWK_LIB='
  BEGIN { n = split(tolower(q), w, " ") }
  function matches(s,   l, i) { l = tolower(s); for (i = 1; i <= n; i++) if (!index(l, w[i])) return 0; return n > 0 }
  function hl(s,   out, l, k, p, best, bl) {
    out = ""
    while (1) { l = tolower(s); best = 0
      for (k = 1; k <= n; k++) if ((p = index(l, w[k])) && (!best || p < best)) { best = p; bl = length(w[k]) }
      if (!best) return out s
      out = out substr(s, 1, best - 1) "\033[1;30;43m" substr(s, best, bl) "\033[0m"; s = substr(s, best + bl) } }
'
# Row layout: type, target, extra (hidden) | status, hits, title, place, kind, age
# Title and place columns share the popup width (TW/WW, set before fzf starts).
ROW_AWK='
  function age(t) { if (!t) return "-"; s = now - t
    return s < 60 ? s "s" : s < 3600 ? int(s/60) "m" : s < 86400 ? int(s/3600) "h" : int(s/86400) "d" }
  # ASCII ellipses: macOS awk pads by bytes, so multibyte ones break alignment.
  function cut(s, w) { return length(s) > w ? substr(s, 1, w - 3) "..." : s }
  function lcut(s, w) { return length(s) > w ? "..." substr(s, length(s) - w + 4) : s }
  function row(type, target, extra, status, color, hits, title, place, kind, t,   tw, ww) {
    tw = ENVIRON["TW"] + 0; ww = ENVIRON["WW"] + 0; if (!tw) tw = 38; if (!ww) ww = 18
    printf "%s\t%s\t%s\t\033[%sm● %-8s\033[0m  \033[1m%5s\033[0m  %-" tw "s  \033[36m%-" ww "s\033[0m  \033[90m%-7s  %6s\033[0m\n",
      type, target, extra, color, status, (hits ? hits : "·"), cut(title, tw), lcut(place, ww), kind, age(t) }
'

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

snapshot() {
  # Sentinel first line keeps awk's NR == FNR trick valid when no session is live.
  { echo "-"; "$H" agent list | jq -r '.result.agents[] | .agent_session.value // empty'; } > "$D/live_sessions"
  "$H" agent list | jq -r '.result.agents[] | select(.focused | not)
    | [.pane_id, .tab_id, .workspace_id, .agent, .agent_status,
       ((.display_agent // .terminal_title_stripped // .agent) | gsub("\""; "")),
       (.foreground_cwd // .cwd), (.agent_session.value // "")] | @tsv' > "$D/agents"
  ws=$("$H" workspace list)
  while IFS="$TAB" read -r pane tab wsid kind status label cwd session; do
    wsl=$(printf '%s' "$ws" | jq -r --arg id "$wsid" '.result.workspaces[] | select(.workspace_id == $id) | .label')
    m=0; [ -f "$session" ] && m=$(mtime "$session")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pane" "$tab" "$kind" "$status" "$label" "$wsl" "$m"
  done < "$D/agents" > "$D/meta"
  touch "$D/meta_ready"  # enough to list agents
  # Fresh reads cost ~6ms per line (~3s), so search the previous snapshot from
  # the cache right away and swap in fresh content as each read finishes.
  mkdir -p "$CACHE"
  cached=1
  while read -r pane _; do
    if [ -f "$CACHE/$pane" ]; then cp "$CACHE/$pane" "$D/$pane"; else cached=0; fi
  done < "$D/agents"
  [ "$cached" = 1 ] && touch "$D/ready"
  cut -f1 "$D/agents" | {
    while read -r pane; do
      { "$H" pane read "$pane" --source recent-unwrapped --lines 500 > "$D/$pane.new" &&
        cp "$D/$pane.new" "$CACHE/$pane" && mv "$D/$pane.new" "$D/$pane"; } &
    done
    wait
  }
}

# Atuin-style order: tight matches (exact phrase) first, then most recent,
# then hit count. Input columns: 1 hits, 8 mtime, 9 exact.
rank() { sort -t "$TAB" -k9,9nr -k8,8nr -k1,1nr; }

# Prints "<lines with every word> <1 if any line has the exact phrase, else 0>".
matches_in() {
  awk -v q="$1" "$AWK_LIB"'
    BEGIN { phrase = tolower(q); gsub(/[[:space:]]+/, " ", phrase); sub(/^ /, "", phrase); sub(/ $/, "", phrase) }
    matches($0) { c++; if (index(tolower($0), phrase)) e = 1 }
    END { print c + 0, e + 0 }' "$2"
}

live_rows() {
  q=$1
  while IFS="$TAB" read -r pane tab kind status label wsl m _; do
    set -- "$q" $([ -n "$q" ] && matches_in "$q" "$D/$pane" || echo 0 0)
    [ -n "$q" ] && [ "$2" -eq 0 ] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$pane" "$tab" "$kind" "$status" "$label" "$wsl" "$m" "$3"
  done < "$D/meta" | rank |
  awk -F "$TAB" -v now="$(date +%s)" "$ROW_AWK"'
    BEGIN { col["blocked"] = 31; col["working"] = 33; col["idle"] = 32; col["done"] = 32 }
    { row("live", $2, $3, $5, ($5 in col) ? col[$5] : 90, $1, $6, $7, $4, $8) }'
}

# PCRE: a user/assistant message line containing every query word.
session_pattern() {
  pat='(?i)^(?=.*"(?:role|type)":"(?:user|assistant)")'
  for w in $1; do pat="$pat(?=.*\\Q$w\\E)"; done
  printf '%s' "$pat"
}

history_rows() {
  [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ] || return 0
  dirs=""; for d in "$PI_SESSIONS" "$CLAUDE_SESSIONS"; do [ -d "$d" ] && dirs="$dirs $d"; done
  [ -n "$dirs" ] || return 0
  # shellcheck disable=SC2086
  rg -P -c --no-messages -g '*.jsonl' "$(session_pattern "$1")" $dirs |
    awk -F: 'NR == FNR { live[$0]; next } { n = $NF; sub(/:[0-9]+$/, ""); if (!($0 in live)) print n "\t" $0 }' \
      "$D/live_sessions" - > "$D/all.$$"
  [ -s "$D/all.$$" ] || { rm -f "$D/all.$$"; return 0; }
  all=$(cut -f2 "$D/all.$$")
  phrase=$(echo $1)
  # Add mtime and exact-phrase columns for every match, rank, then keep the top.
  # shellcheck disable=SC2086
  {
    stat -f '%N:M%m' $all 2>/dev/null || stat -c '%n:M%Y' $all
    case "$phrase" in
      *" "*) rg --no-messages -i -F -l -- "$phrase" $all | sed 's/$/:E/' ;;
      *) printf '%s:E\n' $all ;;  # one word: every match is exact
    esac
  } | awk -F "$TAB" 'FNR == NR { i = index($0, ":"); f = substr($0, 1, i - 1); v = substr($0, i + 1)
                                 if (v == "E") ex[f] = 1; else mt[f] = substr(v, 2); next }
      { print $1 "\t" $2 "\t\t\t\t\t\t" mt[$2] "\t" ($2 in ex) }' - "$D/all.$$" |
    rank | head -n "$HISTORY_LIMIT" > "$D/hist.$$"
  rm -f "$D/all.$$"
  files=$(cut -f2 "$D/hist.$$")
  # One rg pass each for titles, first prompts and cwds across the top files only.
  # shellcheck disable=SC2086
  {
    rg --no-messages -H -o -r 'T$1$2' '"type":"session_info".*"name":"([^"]{1,200})|"aiTitle":"([^"]{1,200})' $files
    rg --no-messages -H -m1 -o -r 'P$1' '"role":"user","content":(?:\[\{"type":"text","text":)?"([^"]{1,200})' $files
    rg --no-messages -H -m1 -o -r 'C$1' '"cwd":"([^"]*)"' $files
  } > "$D/info.$$"
  awk -F "$TAB" -v now="$(date +%s)" -v pi="$PI_SESSIONS" -v home="$HOME" "$ROW_AWK"'
    FNR == NR { i = index($0, ":"); f = substr($0, 1, i - 1); k = substr($0, i + 1, 1); v = substr($0, i + 2)
      if (k == "T") title[f] = v; else if (k == "P") prompt[f] = v; else cwd[f] = v; next }
    { f = $2; kind = index(f, pi) == 1 ? "pi" : "claude"
      t = (f in title) ? title[f] : (f in prompt) ? prompt[f] : "(untitled)"
      gsub(/\\n/, " ", t); p = cwd[f]; if (index(p, home) == 1) p = "~" substr(p, length(home) + 1)
      row(kind, f, cwd[f], "history", 90, $1, t, p, kind, $8) }' "$D/info.$$" "$D/hist.$$"
  rm -f "$D/hist.$$" "$D/info.$$"
}

preview_live() {
  IFS="$TAB" read -r _ _ kind status label wsl _ <<EOF
$(grep "^$1$TAB" "$D/meta")
EOF
  cwd=$(grep "^$1$TAB" "$D/agents" | cut -f7)
  printf '\033[1m%s\033[0m  %s · %s · %s\n%s\n\n' "$label" "$kind" "$status" "$wsl" "$cwd"
  if [ -z "$2" ]; then
    if [ -f "$D/ready" ]; then tail -40 "$D/$1"; else "$H" pane read "$1" --source visible; fi
    return
  fi
  # Each hit with 2 lines of context, gaps marked, query words highlighted.
  awk -v q="$2" "$AWK_LIB"'
    { line[NR] = $0; hit[NR] = matches($0) }
    END { last = 0
      for (i = 1; i <= NR; i++) if (hit[i]) for (j = i - 2; j <= i + 2; j++) if (j > last && j >= 1 && j <= NR) {
        if (last && j > last + 1) print "\033[90m──\033[0m"
        printf "\033[90m%4d│\033[0m %s\n", j, hl(line[j]); last = j } }' "$D/$1"
}

preview_history() {
  printf '\033[1m%s\033[0m  %s · past session\n%s\n\n' "$(basename "$1" .jsonl)" "$3" "$4"
  rg -P --no-messages "$(session_pattern "$2")" "$1" |
    jq -r '[(.message.role // .type), (.timestamp // "" | .[0:16]),
            (.message.content | if type == "string" then . else (map(.text // .thinking // empty) | join(" ")) end)]
           | @tsv' 2>/dev/null | tail -20 |
    awk -F "$TAB" -v q="$2" "$AWK_LIB"'
      $3 == "" { next }
      { t = $3; gsub(/\\[nt]/, " ", t); l = tolower(t); p = 0
        for (k = 1; k <= n; k++) if ((x = index(l, w[k])) && (!p || x < p)) p = x
        s = p > 120 ? p - 120 : 1
        printf "\033[90m%s %-9s│\033[0m %s%s\n\n", $2, $1, (s > 1 ? "…" : ""), hl(substr(t, s, 320)) }'
}

shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

open_session() {
  tab=$("$H" tab create --cwd "${3:-$HOME}" --label "$(basename "$2" .jsonl | cut -c1-20)" --focus)
  pane=$(printf '%s' "$tab" | jq -r '[.. | .pane_id? // empty][0]')
  case "$1" in
    pi) "$H" pane run "$pane" "pi --session $(shq "$2")" >/dev/null ;;
    claude) "$H" pane run "$pane" "claude --resume $(shq "$(basename "$2" .jsonl)")" >/dev/null ;;
  esac
}

# fzf kills a running reload when you type, so the snapshot runs outside fzf
# and every reload/preview waits for it to finish.
# An empty query only needs the agent list, not the slow pane reads.
wait_ready() {
  f=ready; [ -z "$1" ] && f=meta_ready
  while [ ! -f "$D/$f" ]; do sleep 0.05; done
}

case "$1" in
  --rows) D="$2"; wait_ready "$3"; live_rows "$3"; history_rows "$3"; exit ;;
  --preview) D="$2"; wait_ready "$6"
    if [ "$3" = live ]; then preview_live "$4" "$6"; else preview_history "$4" "$6" "$3" "$5"; fi; exit ;;
esac

D=$(mktemp -d)
( snapshot; touch "$D/ready" ) &
SNAP=$!
trap 'kill $SNAP 2>/dev/null; rm -rf "$D"' EXIT
# Fixed columns + separators take 41 cells; title gets ~70% of the rest.
cols=$(tput cols 2>/dev/null || echo 120)
rest=$((cols - 41)); TW=$((rest * 70 / 100)); WW=$((rest - TW))
[ "$TW" -lt 20 ] && TW=20; [ "$WW" -lt 10 ] && WW=10
export TW WW
header=$(printf '%-10s  %5s  %-*s  %-*s  %-7s  %6s' STATUS HITS "$TW" AGENT "$WW" WHERE KIND ACTIVE)
sel=$(: | fzf --ansi --disabled --delimiter="$TAB" --with-nth=4.. --reverse \
  --prompt='search> ' --header="$header" --header-first \
  --bind "start:reload:'$SELF' --rows '$D' ''" \
  --bind "change:reload:'$SELF' --rows '$D' {q}" \
  --preview "'$SELF' --preview '$D' {1} {2} {3} {q}" --preview-window=down,60%,wrap) || exit 0

type=$(printf '%s' "$sel" | cut -f1)
target=$(printf '%s' "$sel" | cut -f2)
extra=$(printf '%s' "$sel" | cut -f3)
if [ "$type" = live ]; then
  "$H" tab focus "$extra" >/dev/null
  "$H" agent focus "$target" >/dev/null 2>&1 || true
else
  open_session "$type" "$target" "$extra"
fi
