# Session Lifecycle

claudecode.nvim manages two orthogonal data sources that are merged in the session picker:

- **Running terminals** — tracked in-memory by `terminal_manager` (`lua/claudecode/terminal_manager.lua`)
- **Session files** — JSONL files on disk at `~/.claude/projects/{cwd-hash}/{uuid}.jsonl`, written by the Claude CLI

The status badges (`●`, `○`, `✕`, `·`) describe the running terminal layer only.

## Full Lifecycle Arc

```
spawned → ● LIVE → (hide) → ○ BG → (show) → ● LIVE
                                 ↓ (process exits)
                              ✕ DEAD   ← stuck here until Neovim restarts
                                 ↓ (next Neovim start, in-memory list wiped)
                            · HISTORY  ← lives on as a JSONL file on disk
                                 ↓ (select in picker)
                              ● LIVE   ← resumed via claude --resume
```

## Terminal States

```
                ┌─────────────────────────────────┐
                │       open_new_terminal()        │
                │  (new session or --resume)       │
                └──────────────┬──────────────────┘
                               │
                               ▼
                          ● active
                     (window open, focused)
                      active_id = this.id
                    /                     \
          hide_active()              process exits /
       (toggle/close/open          BufWipeout / TermClose
        another session)                   │
                │                          ▼
                ▼                       ✕  dead
           ○  background        (cannot be recovered;
       (process still running,   entry stays in-memory
        window hidden)           until plugin restarts)
                │
          switch_to() /
        show_picker select
                │
                ▼
          ● active  (again)
```

### `● active`

- The terminal window is open and focused.
- `active_id` points to this session's internal ID.
- Triggered by: `open_new_terminal()`, `M.switch_to()`, `M.resume_session()` when a live terminal already exists.

### `○ background`

- The process is still running but the window is hidden.
- Triggered by: `hide_active()` — called when toggling, opening a new session, or switching to another session.
- Recoverable: selecting it in the picker calls `M.switch_to()` → back to `● active`.

### `✕ dead`

The Claude CLI process has exited. Think of it like a browser tab that crashed — the tab still appears in the tab bar, but the page is gone. You cannot type in it or resume it directly.

What keeps it visible: the plugin never removes entries from its in-memory list during a Neovim session. The record stays there as a tombstone so you can see the session existed.

What happens next: the conversation is not lost. The JSONL file is still on disk. On the next Neovim start the in-memory list is wiped, but the file is still there, so the session reappears as `· HISTORY` — and from there you can resume it normally.

Causes: closing the terminal window, Claude CLI exiting on its own, or `M.kill_session()`.

## The `· inactive` / HISTORY State

This is **not a terminal state** — there is no entry in the `sessions` table. It comes exclusively from JSONL files on disk that have no matching running terminal.

When the picker builds its item list it merges both sources:

| Has JSONL file | Has live terminal  |        Displayed as         |
| :------------: | :----------------: | :-------------------------: |
|      yes       |   yes (`active`)   |          `●` LIVE           |
|      yes       | yes (`background`) |           `○` BG            |
|      yes       |    yes (`dead`)    |          `✕` DEAD           |
|      yes       |         no         |         `·` HISTORY         |
|       no       |        yes         | `●` / `○` / `✕` (anonymous) |

Selecting a `· inactive` item calls `M.resume_session(uuid)`, which spawns a new terminal with `claude --resume <uuid>`, transitioning it to `● active`.

## State Summary

| Badge | Label   |   Terminal entry?   | Window open? | Process alive? |
| ----- | ------- | :-----------------: | :----------: | :------------: |
| `●`   | LIVE    |         yes         |     yes      |      yes       |
| `○`   | BG      |         yes         |      no      |      yes       |
| `✕`   | DEAD    | yes (until restart) |      no      |       no       |
| `·`   | HISTORY |         no          |      no      |       no       |

## Anonymous Sessions

A session is **anonymous** when a terminal has been spawned (e.g. via `M.new_session()`) but the Claude CLI has not yet written a JSONL file — meaning `claude_session_id` is `nil` on the `ClaudeSessionEntry`. These appear in the picker with a live status badge but no conversation history preview. Once Claude writes its first turn the session file appears on disk and the two are correlated by `claude_session_id`.

## Key Functions

| Function                 | Effect on state                                               |
| ------------------------ | ------------------------------------------------------------- |
| `M.new_session()`        | hides active → spawns new `● active`                          |
| `M.resume_session(uuid)` | hides active → spawns new `● active` resuming that UUID       |
| `M.switch_to(id)`        | hides active → makes target `● active`                        |
| `hide_active()`          | `● active` → `○ background`, clears `active_id`               |
| `M.kill_session(id)`     | forcibly closes window/process → `✕ dead`, removes from table |
| process exit (any)       | `● active` or `○ background` → `✕ dead`                       |

