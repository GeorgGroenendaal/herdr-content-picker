# herdr-content-picker

A [herdr](https://herdr.dev) plugin that fuzzy-searches the visible terminal
content of every open agent pane and jumps straight to the match.

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
- **Scope**: agents currently open in herdr (not the one you're in). Only
  looks at what's currently on screen — herdr doesn't retain scrollback
  history for most agent integrations, so older messages that have scrolled
  away aren't searchable.

## Requirements

`jq`, `fzf`, and a POSIX `awk`/`sh` on your `PATH`.

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
