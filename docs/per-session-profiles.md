# Per-Session Profile Architecture

## Overview

claudecode.nvim supports multiple Claude accounts (profiles) running simultaneously within a single Neovim instance. Each terminal session is independently bound to a profile — one session can use your personal account while another uses your work account, all in the same editor.

## How It Works

### Lockfiles — written once for all profiles

When the Neovim WebSocket server starts, the lock file is written to **every configured profile's lock directory** at once:

```
~/.claude/ide/PORT.lock       ← personal profile finds it
~/.claude-work/ide/PORT.lock  ← work profile finds it
```

All lock files contain the same content (port + auth token). Any Claude CLI process, regardless of which `CLAUDE_CONFIG_DIR` it uses, can discover the Neovim server.

On server stop, lock files are removed from all locations.

### Sessions — each bound to a profile

Every terminal session stores which profile it was opened with. When a session is created:

1. The profile's `CLAUDE_CONFIG_DIR` is injected as an environment variable into the Claude CLI process
2. The session's `profile` field is set and visible in the session picker and Status popup
3. The Claude CLI uses the correct account credentials from that config directory

Sessions from different profiles can coexist:

```
● [personal] New Session 1   ← uses ~/.claude
○ [work]     client-project  ← uses ~/.claude-work
```

### Profile API matching (macOS Keychain)

On macOS, credentials are stored in the Keychain rather than `.credentials.json` files. Since Keychain tokens are opaque (not JWTs), the email cannot be extracted locally. Instead:

1. All Keychain entries matching `Claude Code-credentials*` are enumerated
2. Each token is fetched and passed to the Anthropic profile API (`/api/oauth/profile`)
3. The returned `account.email` is matched against the `account_email` configured for each profile
4. Results are labelled with the correct profile name

This is why the `account_email` field in profile config is important on macOS:

```lua
profiles = {
  personal = { claude_config_dir = "~/.claude",      account_email = "you@gmail.com" },
  work     = { claude_config_dir = "~/.claude-work",  account_email = "you@company.com" },
},
```

## Commands

### `ClaudeCode` / `ClaudeCodeSessionNew`

Opens a new session using the **default profile** (`default_profile` in config, or the currently active profile after a switch). No prompt — fast path.

### `ClaudeCodeSessionFor`

Shows a profile picker, then opens a new session bound to the chosen profile. Use this when you want to open a session for a different account without changing the global default.

```
Select profile for new session:
  personal (default)
  work
```

### `ClaudeCodeProfile`

Changes the **default profile** — which profile `ClaudeCode` and `ClaudeCodeSessionNew` will use for future new sessions. Does not affect already-running sessions.

When active sessions exist, you are prompted to confirm before switching (sessions are killed, the new default takes effect for the next session you open).

## Configuration

```lua
require("claudecode").setup({
  profiles = {
    personal = {
      claude_config_dir = "~/.claude",
      account_email = "you@gmail.com",   -- required on macOS for Keychain matching
    },
    work = {
      claude_config_dir = "~/.claude-work",
      account_email = "you@company.com",
    },
  },
  default_profile = "personal",  -- profile used at startup (nil = system default ~/.claude)
})
```

### Profile fields

| Field               | Type     | Description                                                                       |
| ------------------- | -------- | --------------------------------------------------------------------------------- |
| `claude_config_dir` | `string` | Path to the Claude config directory for this account                              |
| `account_email`     | `string` | Email address of the account (required on macOS for Keychain matching)            |
| `env`               | `table`  | Extra environment variables to inject for this profile (e.g. `ANTHROPIC_API_KEY`) |

### `default_profile`

The profile that Neovim starts with. Set to a key from your `profiles` table. When `nil`, the system default (`~/.claude`) is used.

This is a startup default, not a runtime lock — you can always switch with `ClaudeCodeProfile` or open a session for a different profile with `ClaudeCodeSessionFor`.

## Status Popup (`ClaudeCodeStatus`)

The Status popup shows:

- **Profile** line in the header — the current default profile name
- **Sessions** section — each session labelled with its profile tag `[personal]` / `[work]`
- **Profiles** section — per-account usage bars and plan info for all configured profiles, with `●` marking the default profile

## Design Decisions

### Why write lockfiles to all profile dirs?

The alternative (moving the lockfile on profile switch) breaks multi-session support: if a `work` session and a `personal` session are both running, there is no single "active" location. Writing to all dirs at server start is stateless and handles any combination of active sessions.

### Why not move the lockfile on `ClaudeCodeProfile` switch?

`ClaudeCodeProfile` now only changes the default for future sessions. Existing sessions are not invalidated because their lockfile (in their own profile's dir) is still present. This makes profile switching non-destructive when no active sessions exist.

### Why per-session profile instead of global active profile?

A global active profile forces a choice: you can only work on one account at a time. Per-session profiles let you keep a `work` session open reviewing a PR while opening a `personal` session for a side project — both connected to Neovim's MCP server simultaneously.
