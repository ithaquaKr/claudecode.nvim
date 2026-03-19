# Session Management for claudecode.nvim

**Date:** 2026-03-19
**Status:** Approved

## Overview

Add per-directory Claude session management to claudecode.nvim. When opening a fresh Claude terminal, the user is prompted to start fresh, restore their last session, or choose from past sessions for the current working directory.

## Goals

- Resume past Claude conversations by directory without remembering session IDs manually
- Non-intrusive: prompt only on fresh terminal open, never when a session is already running
- Explicit user args (e.g. `:ClaudeCode --resume xyz`) always bypass the prompt
- No new mandatory dependencies

## Configuration

A new top-level config section is added (default opt-in):

```lua
require("claudecode").setup({
  session_management = {
    enabled = true,  -- set to false to disable entirely and always start fresh
  }
})
```

When `enabled = false`, all session logic is skipped and `terminal.lua` behaves exactly as before.

## User Flow

### On first fresh terminal open (per Neovim session)

"Fresh open" is defined precisely as: `provider.get_active_bufnr()` returns `nil` or a buffer number that fails `vim.api.nvim_buf_is_valid(bufnr)` (i.e. no Claude terminal buffer currently exists in the provider). Hiding and re-showing an existing terminal buffer does **not** count as a fresh open — the buffer still exists.

```
Select Claude session:
  > Start fresh (no session)
    Restore last session  (2026-03-19 14:32 "Read this repo for ready knowledge...")
    Choose session...
```

- **Start fresh** — launches `claude` with no extra args; sets the in-memory "skip prompt" flag for this cwd for the rest of the Neovim session
- **Restore last session** — launches `claude --resume <last_session_id>`; updates the saved preference for this cwd
- **Choose session...** — opens a second picker listing all sessions for the cwd sorted newest-first

**Cancellation:** pressing Escape or dismissing either picker aborts the terminal open entirely. No terminal is opened.

### Session picker (second level)

Each entry: `2026-03-19 14:32  "last user message preview (truncated to ~60 chars)..."`

Sorted newest-first by file mtime (`vim.loop.fs_stat().mtime`). Selecting an entry launches `claude --resume <session_id>` and saves it as the new `last_session_id` for this cwd. Cancelling falls back to no terminal open.

### Conditional display

| Condition | Options shown |
|---|---|
| `session_management.enabled = false` | No prompt — open `claude` directly |
| "Skip" in-memory flag set for this cwd | No prompt — open `claude` directly |
| Explicit `cmd_args` passed by user | No prompt — pass args through directly |
| Not a fresh open (buffer already exists) | No prompt — toggle visibility as normal |
| Saved `last_session_id` exists and `.jsonl` files exist | All three options |
| No saved `last_session_id` but `.jsonl` files exist | Start fresh + Choose session |
| No `.jsonl` files at all | No prompt — open `claude` directly |

### Intercepted entry points

The session prompt is injected in `M.simple_toggle` and `M.focus_toggle` in `terminal.lua` when all bypass conditions above are clear.

`M.open` is **excluded** from the intercept. It is called programmatically from `init.lua`'s mention queue flush path (`send_at_mention`), not from direct user interaction. Intercepting it would block automated mention delivery with an unexpected UI prompt.

`M.ensure_visible` and `M.toggle_open_no_focus` are also **excluded**. Both delegate to `ensure_terminal_visible_no_focus`, which is a no-focus-open path used for programmatic visibility control. As of writing, neither function is called from any internal code path in `init.lua` — they exist as public API for external callers. They are excluded for the same reason as `M.open`: they are automation paths, not user-initiated session starts.

`M.toggle` delegates to `M.simple_toggle` and therefore inherits the session intercept automatically — no additional changes needed.

## Architecture

### New module: `lua/claudecode/session.lua`

Responsibilities:
- Read session list from `~/.claude/projects/<hashed-cwd>/`
- Read/write preferences from `~/.local/share/nvim/claudecode/sessions.json`
- Show the picker UI via `vim.ui.select`
- Track in-memory "skip prompt this Neovim session" state per cwd

Public API:
```lua
-- Resolve which args to pass to claude for this cwd.
-- Calls callback(args_string) where args_string may be nil (start fresh),
-- "--resume <id>" (restore/choose), or false (user cancelled — do not open terminal).
-- If no prompt is needed, callback is called synchronously.
-- If a picker is shown, callback is called from within vim.ui.select's callback (vim.schedule context).
session.resolve_args(cwd, callback)

-- Clear all in-memory state. Called from M.stop() in init.lua.
session.reset()

-- Configure the module. Called from M.setup() in init.lua (not from terminal.setup()).
-- session_management is a top-level plugin config key; init.lua passes it directly.
session.setup(config)  -- config = { enabled = bool }
```

### In-memory state

```lua
-- Module-level in session.lua
local skip_cwd = {}  -- { [canonical_cwd] = true }
```

Keyed by canonical cwd (see below). Set when the user picks "Start fresh". Cleared by `session.reset()`, which is called from `M.stop()` in `init.lua`. The flag is **not** cleared on server restart mid-session — `M.stop()` is the single clear point, which also fires on `VimLeavePre`.

### cwd canonicalisation

All cwd values are normalised before use as keys:

```lua
local function canonical_cwd(raw)
  return vim.fn.fnamemodify(vim.fn.resolve(raw), ":p"):gsub("/$", "")
end
```

`vim.fn.resolve()` expands symlinks. `:p` ensures an absolute path. Trailing slash is stripped. This is applied consistently when:
- Hashing the path to find `~/.claude/projects/<hash>/`
- Keying `sessions.json`
- Setting/checking `skip_cwd`

Hash function: `canonical_cwd:gsub("/", "-")` (replacing all `/` with `-`, matching Claude CLI's convention). This means two paths that differ only in having a `/` vs `-` at the same position could theoretically collide (e.g. `/foo/bar` and `/foo-bar`). This collision risk is accepted intentionally because it matches the exact convention Claude CLI uses — using the same hash ensures we look up the correct directory that Claude itself writes to.

### Data: `~/.local/share/nvim/claudecode/sessions.json`

```json
{
  "/Users/foo/myproject": {
    "last_session_id": "b86a2915-e00a-407d-b7cb-ab46de6989df",
    "updated_at": "2026-03-19T14:32:00Z"
  }
}
```

Only `last_session_id` is persisted. The "skip prompt" flag lives in module-level Lua state only. `updated_at` is informational only (records when the preference was last saved); it is never read back by the session module.

**Write strategy:** writes use an atomic pattern — write to a temp file in the same directory, then `vim.loop.fs_rename()` to replace. This prevents data corruption if two Neovim instances write simultaneously (last writer wins, no partial file).

### Reading sessions from Claude's storage

Claude stores sessions at: `~/.claude/projects/<hashed-cwd>/<uuid>.jsonl`

For each `.jsonl` file:
- **Timestamp**: `vim.loop.fs_stat(path)` — if stat returns nil (file disappeared between directory listing and stat), skip the file. Otherwise use `.mtime.sec`.
- **Preview**: read lines, find the **last** line where `type == "user"` and `message.role == "user"`, extract text:
  - If `message.content` is a string — use it directly
  - If `message.content` is a table — find first entry with `type == "text"`, use `.text`
  - If no user message found — display `"(no preview)"`
  - If a line fails JSON parsing — skip it and continue
  - Truncate preview to 60 characters with `...` suffix if longer

### Integration with `terminal.lua`

The intercept lives in `M.simple_toggle` and `M.focus_toggle`. The key requirement is that `build_config` and `get_claude_command_and_env` are called **before** `session.resolve_args` so their values (which capture `vim.fn.getcwd()`, `vim.fn.expand("%:p")`, etc.) are not stale after the async picker interaction.

```lua
-- Pseudocode for the intercepted path in M.simple_toggle / M.focus_toggle
local provider = get_provider()
local is_fresh = not is_valid_buffer(provider.get_active_bufnr())

if is_fresh and (not cmd_args or cmd_args == "") and session_enabled then
  -- Capture config NOW, before async gap
  local effective_config = build_config(opts_override)
  local cwd = vim.fn.getcwd()

  session.resolve_args(cwd, function(resolved_args)
    if resolved_args == false then return end  -- user cancelled
    local cmd_string, env = get_claude_command_and_env(resolved_args)
    provider.open(cmd_string, env, effective_config, focus)
  end)
else
  -- Unchanged synchronous path
  local effective_config = build_config(opts_override)
  local cmd_string, env = get_claude_command_and_env(cmd_args)
  provider.open(cmd_string, env, effective_config, focus)
end
```

`vim.ui.select` callbacks run inside a `vim.schedule` context, which is safe for all Vim API calls used by `provider.open()`.

## Files Changed

| File | Change |
|---|---|
| `lua/claudecode/session.lua` | New module |
| `lua/claudecode/terminal.lua` | Intercept `M.simple_toggle` and `M.focus_toggle` for fresh opens |
| `lua/claudecode/init.lua` | Call `session.setup(config.session_management)` from `M.setup()`; call `session.reset()` from `M.stop()` |
| `lua/claudecode/config.lua` | Add `session_management = { enabled = true }` default and boolean validator for `session_management.enabled` |
| `tests/unit/session_spec.lua` | New unit tests |

## Testing

- Session list reading: mock fs with various `.jsonl` structures, empty dir, missing dir, unreadable file, active-write truncation (invalid JSON line)
- JSONL preview parsing: string content, table content, no user message, deeply nested, 60-char truncation
- Preference file: missing file (first run), malformed JSON, write failure, atomic rename path
- Picker logic: all three option variants, cancellation at both levels, callback values
- Terminal integration: fresh open triggers prompt; hidden-then-shown buffer does not; explicit args bypass; `M.open` bypasses; `enabled = false` bypasses
- In-memory flag: set on "Start fresh", persists across toggles in same session, cleared by `session.reset()`
- cwd canonicalisation: symlinks, trailing slash, absolute path enforcement

## Non-Goals

- No UI for deleting or renaming sessions (Claude manages those files)
- No syncing session preferences across machines
- No changes to how Claude stores or identifies sessions
- No session management in `M.open` (programmatic path)
