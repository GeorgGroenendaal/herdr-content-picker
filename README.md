# herdr-content-picker

A [herdr](https://herdr.dev) plugin that searches the terminal content of every
open agent pane, plus your past pi and Claude Code sessions, and jumps straight
to the match.

Herdr's built-in Goto picker (`prefix+g`) searches names, tabs, and paths.
This plugin searches the actual terminal output: one row per agent, ranked by
how many lines match your query, with a preview of the matching lines in
context.

```
search> rate limit retry
STATUS      HITS  AGENT                                  WORKSPACE          KIND    ACTIVE
▌● working     7  Fix flaky checkout tests               checkout-service   pi         2h
 ● working     1  Add retry backoff to API client        api-client         pi         1s
```

- **Rows**: colored status dot (blocked/working/idle/done), hit count, agent
  name, workspace, agent type, and time since the agent last wrote its
  session file. Sorted by hit count, most first.
- **Matching**: a line matches when it contains every word you typed, in any
  order, case-insensitively. Empty query lists all open agents.
- **Preview**: matching lines with 2 lines of surrounding context, query
  words highlighted, gaps marked.
- **Live agents**: the last 500 lines of every open agent pane (not the one
  you're in). Enter focuses the agent.
- **Past sessions**: pi (`~/.pi/agent/sessions`) and Claude Code
  (`~/.claude/projects`) transcripts, searched with ripgrep and listed below
  live agents (top 50 by hits). Enter resumes the session in a new tab.
  Override the locations with `PI_SESSIONS` / `CLAUDE_SESSIONS`.

## Requirements

`jq`, `fzf`, `rg` (ripgrep), and a POSIX `awk`/`sh` on your `PATH`.

## Install

```sh
herdr plugin install georggroenendaal/herdr-content-picker
```

## Bind a key

The plugin only registers an action; bind a key to it in your
`~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+f"
type = "plugin_action"
command = "georggroenendaal.content-picker.search"
description = "fuzzy search terminal content"
```

Then `herdr server reload-config` (or `prefix+shift+r` inside herdr).

## Develop locally

```sh
herdr plugin link /path/to/herdr-content-picker
herdr plugin action invoke georggroenendaal.content-picker.search
```
