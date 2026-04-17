---Multi-session terminal management for claudecode.nvim.
---Manages multiple running Claude CLI terminal sessions per working directory,
---with show/hide (background) support and a Snacks-based quick switcher.
---
---The switcher merges two sources:
---  • Running terminals tracked by this module (active / background / dead)
---  • Historical Claude CLI session files in ~/.claude/projects/{hash}/
---Sessions that appear in both are shown with a live-status icon; sessions
---that only exist on disk (no running terminal) are shown as "inactive" and
---can be re-activated (equivalent to --resume) by selecting them.
---@module 'claudecode.terminal_manager'

local M = {}

---@class ClaudeSessionEntry
---@field id string Unique internal ID for this Neovim terminal instance
---@field bufnr number Neovim buffer number
---@field jobid number Terminal job ID (from vim.fn.termopen)
---@field label string Display label (Claude session preview or "New Session N")
---@field cwd string Working directory this session was opened in
---@field claude_session_id string|nil UUID of the Claude CLI session file, if known
---@field status "active"|"background"|"dead" Visibility/alive state
---@field created_at number Unix timestamp of creation

---@type ClaudeSessionEntry[]
local sessions = {}

---@type string|nil
local active_id = nil

---@type table Terminal config (split_side, split_width_percentage, terminal_cmd, env, auto_close)
local _cfg = {}

--- Generate a simple unique ID
local function gen_id()
  local r = math.random
  return string.format(
    "%04x%04x-%04x-%04x-%04x-%04x%04x%04x",
    r(0, 0xffff),
    r(0, 0xffff),
    r(0, 0xffff),
    r(0x4000, 0x4fff),
    r(0x8000, 0xbfff),
    r(0, 0xffff),
    r(0, 0xffff),
    r(0, 0xffff)
  )
end

---@param id string
---@return ClaudeSessionEntry|nil, number|nil
local function find_by_id(id)
  for i, s in ipairs(sessions) do
    if s.id == id then
      return s, i
    end
  end
  return nil, nil
end

---@param cwd string
---@return ClaudeSessionEntry[]
local function sessions_for_cwd(cwd)
  local result = {}
  for _, s in ipairs(sessions) do
    if s.cwd == cwd then
      table.insert(result, s)
    end
  end
  return result
end

---@param bufnr number
---@return boolean
local function is_buf_visible(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local info = vim.fn.getbufinfo(bufnr)
  return info and #info > 0 and #info[1].windows > 0
end

--- Hide all windows displaying a buffer without killing the process.
---@param bufnr number
local function hide_buf_windows(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      if #vim.api.nvim_list_wins() > 1 then
        vim.api.nvim_win_hide(win)
      end
    end
  end
end

--- Find the best editor window to split from: non-floating, non-terminal.
--- Falls back to current window if nothing better exists.
---@return number winid
local function find_editor_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local cfg = vim.api.nvim_win_get_config(w)
      if not cfg.relative or cfg.relative == "" then
        local wbuf = vim.api.nvim_win_get_buf(w)
        if vim.bo[wbuf].buftype ~= "terminal" then
          return w
        end
      end
    end
  end
  return vim.api.nvim_get_current_win()
end

--- Open a split window from a proper editor window and show a buffer in it.
--- When bufnr is nil a fresh empty buffer (enew) is used — suitable for new terminals.
--- When bufnr is given the existing buffer (e.g. a running terminal) is displayed.
---@param bufnr number|nil Existing buffer to show, or nil to create a fresh one
---@return number winid The new split window ID
local function open_in_split(bufnr)
  local side = _cfg.split_side or "right"
  local pct = _cfg.split_width_percentage or 0.30
  local width = math.floor(vim.o.columns * pct)
  local placement = (side == "right") and "botright" or "topleft"

  -- Always split from a real editor window, never from a floating window or
  -- a terminal buffer — otherwise window layout and <C-w> navigation break.
  vim.api.nvim_set_current_win(find_editor_win())

  vim.cmd(placement .. " " .. width .. "vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, vim.o.lines)

  if bufnr then
    vim.api.nvim_win_set_buf(win, bufnr)
  else
    -- Use enew so termopen gets a clean, unnamed buffer (same as native provider)
    vim.api.nvim_win_call(win, function()
      vim.cmd("enew")
    end)
  end

  return win
end

--- Extract plain text from a Claude message content field.
--- Content can be a plain string or an array of {type,text} blocks.
---@param content any
---@return string
local function extract_text_from_content(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return ""
  end
  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts, "\n")
end

--- Read a Claude CLI session JSONL file and return formatted lines for preview.
--- Shows the conversation exchanges (user + assistant turns only) as markdown.
--- Reads only the tail of large files for performance.
---@param session_file string Absolute path to the .jsonl file
---@return string[]
local function parse_session_for_preview(session_file)
  local file = io.open(session_file, "r")
  if not file then
    return { "(could not open session file)" }
  end

  -- Collect all lines first; for large files we only care about the tail
  local raw_lines = {}
  for line in file:lines() do
    table.insert(raw_lines, line)
  end
  file:close()

  -- Process only the last 300 lines to keep parsing fast
  local start_idx = math.max(1, #raw_lines - 300)
  local turns = {}

  for i = start_idx, #raw_lines do
    local ok, entry = pcall(vim.json.decode, raw_lines[i])
    if ok and type(entry) == "table" then
      local role = entry.type -- "user" or "assistant"
      if (role == "user" or role == "assistant") and type(entry.message) == "table" then
        local text = extract_text_from_content(entry.message.content)
        -- Strip internal command/tool XML noise Claude CLI injects
        text = text:gsub("<command%-message>.-</command%-message>", "")
        text = text:gsub("<command%-name>.-</command%-name>", "")
        text = text:match("^%s*(.-)%s*$") or text
        if text ~= "" then
          table.insert(turns, { role = role, text = text })
        end
      end
    end
  end

  if #turns == 0 then
    return { "(no conversation content found)" }
  end

  -- Format the last 20 turns as markdown
  local lines = {}
  local show_from = math.max(1, #turns - 20)
  if show_from > 1 then
    table.insert(lines, string.format("*… %d earlier exchanges not shown …*", show_from - 1))
    table.insert(lines, "")
  end

  for i = show_from, #turns do
    local turn = turns[i]
    local header = turn.role == "user" and "## 👤 User" or "## 🤖 Claude"
    table.insert(lines, header)
    table.insert(lines, "")
    for _, l in ipairs(vim.split(turn.text, "\n", { plain = true })) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  return lines
end

--- Build claude command string and environment table.
---@param resolved_args string|nil Args from session picker (e.g. "--resume UUID")
---@return string cmd, table env
local function build_cmd_env(resolved_args)
  local server = require("claudecode.server.init")
  local base = _cfg.terminal_cmd or "claude"
  local cmd = (resolved_args and resolved_args ~= "") and (base .. " " .. resolved_args) or base

  local env = {
    ENABLE_IDE_INTEGRATION = "true",
    FORCE_CODE_TERMINAL = "true",
  }
  if server.state and server.state.port then
    env.CLAUDE_CODE_SSE_PORT = tostring(server.state.port)
  end
  for k, v in pairs(_cfg.env or {}) do
    env[k] = v
  end

  return cmd, env
end

--- Extract the Claude CLI session UUID from resolved_args string.
---@param resolved_args string|nil
---@return string|nil
local function extract_claude_session_id(resolved_args)
  if not resolved_args or resolved_args == "" then
    return nil
  end
  return resolved_args:match("--resume%s+(%S+)")
end

--- Derive a display label for a terminal session.
--- For resume sessions, looks up the preview text from the Claude JSONL file.
---@param resolved_args string|nil
---@param cwd string
---@return string
local function derive_label(resolved_args, cwd)
  local sid = extract_claude_session_id(resolved_args)

  if not sid then
    local n = #sessions_for_cwd(cwd) + 1
    return "New Session " .. n
  end

  local ok, session_module = pcall(require, "claudecode.session")
  if ok then
    local ok2, list = pcall(session_module._list_sessions, cwd)
    if ok2 and list then
      for _, se in ipairs(list) do
        if se.id == sid then
          local preview = (se.preview and se.preview ~= "(no preview)") and se.preview or nil
          if preview then
            return #preview > 55 and (preview:sub(1, 52) .. "…") or preview
          end
          if se.formatted then
            return se.formatted:sub(1, 40) .. "…"
          end
          break
        end
      end
    end
  end

  return "Session " .. sid:sub(1, 8) .. "…"
end

--- Core: spawn a terminal process in an already-open split window.
--- The split must already be open and be the current window.
---@param win number Window ID where the terminal should open
---@param cmd string Claude CLI command string
---@param env table Environment variables
---@param label string Display label for the session
---@param cwd string Working directory
---@param claude_session_id string|nil Claude CLI session UUID (nil for fresh sessions)
local function spawn_terminal(win, cmd, env, label, cwd, claude_session_id)
  local bufnr = vim.api.nvim_win_get_buf(win)
  local session_id = gen_id()

  ---@type ClaudeSessionEntry
  local entry = {
    id = session_id,
    bufnr = bufnr,
    jobid = -1,
    label = label,
    cwd = cwd,
    claude_session_id = claude_session_id,
    status = "active",
    created_at = os.time(),
  }

  local cmd_list = cmd:find(" ", 1, true)
      and vim.split(cmd, " ", { plain = true, trimempty = true })
    or { cmd }
  local jobid = vim.fn.termopen(cmd_list, {
    env = env,
    cwd = cwd,
    on_exit = function(_, _, _)
      vim.schedule(function()
        local s = find_by_id(session_id)
        if not s then
          return
        end
        s.status = "dead"
        if active_id == session_id then
          active_id = nil
        end
        if _cfg.auto_close ~= false then
          hide_buf_windows(s.bufnr)
        end
      end)
    end,
  })

  if not jobid or jobid <= 0 then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    vim.notify("claudecode: failed to start claude process", vim.log.levels.ERROR)
    return
  end

  -- termopen may have allocated a new buffer number; read it back
  entry.bufnr = vim.api.nvim_win_get_buf(win)
  entry.jobid = jobid
  table.insert(sessions, entry)
  active_id = session_id

  -- Defer startinsert so any typeahead queued before the terminal opens is flushed first
  vim.schedule(function()
    vim.cmd("startinsert")
  end)
end

--- Hide the currently active session's window (keeps process running).
local function hide_active()
  if not active_id then
    return
  end
  local s = find_by_id(active_id)
  if s and vim.api.nvim_buf_is_valid(s.bufnr) then
    hide_buf_windows(s.bufnr)
    if s.status == "active" then
      s.status = "background"
    end
  end
  active_id = nil
end

--- Initialize the manager with the plugin's terminal config.
---@param term_cfg table Terminal config table from plugin setup
function M.setup(term_cfg)
  _cfg = term_cfg or {}
end

--- Open a brand-new Claude session (shows the session-resume picker first).
--- After the user picks (fresh/resume/choose), a new terminal is spawned and
--- becomes the active session. The previous active session is hidden.
function M.new_session()
  local ok, session_module = pcall(require, "claudecode.session")
  if not ok or not session_module.is_setup then
    session_module = nil
  end

  local cwd = vim.fn.getcwd()

  local function open_terminal(resolved_args)
    local claude_session_id = extract_claude_session_id(resolved_args)
    local label = derive_label(resolved_args, cwd)
    local cmd, env = build_cmd_env(resolved_args)

    hide_active()
    local win = open_in_split(nil)
    spawn_terminal(win, cmd, env, label, cwd, claude_session_id)
  end

  if session_module then
    session_module.resolve_args(cwd, function(resolved_args)
      if resolved_args == false then
        return -- user cancelled picker
      end
      open_terminal(resolved_args)
    end)
  else
    open_terminal(nil)
  end
end

--- Resume a specific Claude CLI session by its UUID, bypassing the session picker.
--- If a terminal for that session is already running, switch to it instead.
---@param claude_session_id string The Claude CLI session UUID to resume
---@param cwd string|nil Working directory (defaults to vim.fn.getcwd())
function M.resume_session(claude_session_id, cwd)
  cwd = cwd or vim.fn.getcwd()

  -- If there's already a live terminal for this Claude session, just switch to it
  for _, s in ipairs(sessions_for_cwd(cwd)) do
    if s.claude_session_id == claude_session_id and s.status ~= "dead" then
      M.switch_to(s.id)
      return
    end
  end

  -- No running terminal — open a new one resuming this session
  local resolved_args = "--resume " .. claude_session_id
  local label = derive_label(resolved_args, cwd)
  local cmd, env = build_cmd_env(resolved_args)

  hide_active()
  local win = open_in_split(nil)
  spawn_terminal(win, cmd, env, label, cwd, claude_session_id)
end

--- Switch to a running session by its internal terminal ID.
--- Hides the current active session and shows the target session's buffer.
---@param session_id string
function M.switch_to(session_id)
  local s = find_by_id(session_id)
  if not s then
    vim.notify("claudecode: session not found", vim.log.levels.WARN)
    return
  end

  if s.status == "dead" or not vim.api.nvim_buf_is_valid(s.bufnr) then
    vim.notify("claudecode: session has already exited", vim.log.levels.WARN)
    return
  end

  if session_id == active_id then
    -- Already active — just ensure it's visible
    if not is_buf_visible(s.bufnr) then
      open_in_split(s.bufnr)
      vim.schedule(function()
        vim.cmd("startinsert")
      end)
    end
    return
  end

  hide_active()
  open_in_split(s.bufnr)
  s.status = "active"
  active_id = session_id
  -- Defer startinsert so any typeahead from picker/<CR> is flushed first
  vim.schedule(function()
    vim.cmd("startinsert")
  end)
end

--- Kill (terminate and remove) a running session by its internal terminal ID.
--- If it was the active session, switches to the most recent live session or does nothing.
---@param session_id string
function M.kill_session(session_id)
  local s, idx = find_by_id(session_id)
  if not s then
    return
  end

  local was_active = (active_id == session_id)
  local prev_cwd = s.cwd

  if s.jobid and s.jobid > 0 then
    pcall(vim.fn.jobstop, s.jobid)
  end
  if vim.api.nvim_buf_is_valid(s.bufnr) then
    hide_buf_windows(s.bufnr)
    pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
  end

  table.remove(sessions, idx)

  if was_active then
    active_id = nil
    local remaining = sessions_for_cwd(prev_cwd)
    for i = #remaining, 1, -1 do
      if remaining[i].status ~= "dead" and vim.api.nvim_buf_is_valid(remaining[i].bufnr) then
        M.switch_to(remaining[i].id)
        return
      end
    end
  end
end

--- Toggle the active session: hide if visible, show if hidden.
--- If no sessions exist for the current cwd, opens a new one.
function M.toggle()
  local cwd = vim.fn.getcwd()

  if active_id then
    local s = find_by_id(active_id)
    if s and s.status ~= "dead" and vim.api.nvim_buf_is_valid(s.bufnr) then
      if is_buf_visible(s.bufnr) then
        hide_active()
      else
        open_in_split(s.bufnr)
        s.status = "active"
        vim.schedule(function()
          vim.cmd("startinsert")
        end)
      end
      return
    end
    active_id = nil
  end

  -- Try to restore a background session for this cwd
  local cwd_sessions = sessions_for_cwd(cwd)
  for i = #cwd_sessions, 1, -1 do
    local s = cwd_sessions[i]
    if s.status == "background" and vim.api.nvim_buf_is_valid(s.bufnr) then
      open_in_split(s.bufnr)
      s.status = "active"
      active_id = s.id
      vim.schedule(function()
        vim.cmd("startinsert")
      end)
      return
    end
  end

  M.new_session()
end

--- Kill the currently active session (if any).
function M.kill_active()
  if active_id then
    M.kill_session(active_id)
  else
    vim.notify("claudecode: no active session to kill", vim.log.levels.WARN)
  end
end

--- Return all sessions (optionally filtered by cwd).
---@param cwd string|nil If given, only return sessions for this cwd
---@return ClaudeSessionEntry[]
function M.get_sessions(cwd)
  if cwd then
    return sessions_for_cwd(cwd)
  end
  return sessions
end

--- Return the currently active session, or nil.
---@return ClaudeSessionEntry|nil
function M.get_active()
  if not active_id then
    return nil
  end
  return find_by_id(active_id)
end

--- Show the Snacks-based session quick switcher for the given cwd.
---
--- Items are built by merging two sources:
---   1. Running terminal sessions tracked by this module
---   2. Historical Claude CLI session files for the project directory
--- Sessions that appear in both show a live-status icon (● active, ○ background, ✗ dead).
--- Sessions that only exist on disk (inactive) show a blank status icon and can be
--- re-activated (equivalent to --resume) by pressing <CR>.
---
--- Keybindings:
---   <CR>   — switch to / resume selected session
---   dd     — kill selected session's terminal (running only; no-op for inactive)
---   <C-d>  — same as dd in insert mode
---   <C-n>  — open a new session (shows session-resume picker)
---@param cwd string|nil Defaults to vim.fn.getcwd()
function M.show_picker(cwd)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("claudecode: snacks.nvim is required for the session switcher", vim.log.levels.ERROR)
    return
  end

  cwd = cwd or vim.fn.getcwd()

  --- Build merged item list from running terminals + Claude CLI session files.
  --- Each item includes a `session_file` path so the preview function can read it.
  ---@return table[]
  local function build_items()
    local items = {}

    -- Resolve the session directory once for file path construction
    local session_dir = nil
    local session_ok, session_module = pcall(require, "claudecode.session")
    if session_ok then
      local ok_c, canonical = pcall(session_module._canonical_cwd, cwd)
      if ok_c then
        local ok_h, hash = pcall(session_module._hash_cwd, canonical)
        if ok_h then
          session_dir = vim.fn.expand("~/.claude/projects/") .. hash .. "/"
        end
      end
    end

    -- Running terminal sessions indexed by their claude_session_id (for dedup below)
    local running_by_claude_id = {}
    for _, s in ipairs(sessions_for_cwd(cwd)) do
      if s.claude_session_id then
        running_by_claude_id[s.claude_session_id] = s
      end
    end

    -- 1. Running terminals with NO Claude session ID (fresh / anonymous starts)
    for _, s in ipairs(sessions_for_cwd(cwd)) do
      if not s.claude_session_id then
        local icon = s.status == "active" and "● " or (s.status == "background" and "○ " or "✗ ")
        table.insert(items, {
          text = icon .. s.label,
          kind = "running",
          terminal_id = s.id,
          session_status = s.status,
          session_file = nil, -- no JSONL file for anonymous sessions
        })
      end
    end

    -- 2. Claude CLI session files — running ones annotated with live status
    if session_ok then
      local ok2, claude_sessions = pcall(session_module._list_sessions, cwd)
      if ok2 and claude_sessions then
        for _, cs in ipairs(claude_sessions) do
          local running = running_by_claude_id[cs.id]
          local icon, kind, status

          if running then
            if running.status == "active" then
              icon = "● "
            elseif running.status == "background" then
              icon = "○ "
            else
              icon = "✗ "
            end
            kind = "running"
            status = running.status
          else
            icon = "  "
            kind = "inactive"
            status = "inactive"
          end

          local preview_text = (cs.preview and cs.preview ~= "(no preview)") and cs.preview
            or cs.id:sub(1, 8) .. "…"
          local label = #preview_text > 55 and (preview_text:sub(1, 52) .. "…") or preview_text

          table.insert(items, {
            text = icon .. label,
            kind = kind,
            terminal_id = running and running.id or nil,
            claude_session_id = cs.id,
            session_status = status,
            session_file = session_dir and (session_dir .. cs.id .. ".jsonl") or nil,
          })
        end
      end
    end

    if #items == 0 then
      table.insert(items, {
        text = "  No sessions — press <C-n> to open one",
        kind = "hint",
        session_file = nil,
      })
    end

    return items
  end

  Snacks.picker.pick({
    title = "Claude Code Sessions",
    items = build_items(),
    format = "text",
    -- Show conversation content from the Claude CLI session JSONL file
    preview = function(ctx)
      local item = ctx.item
      if not item or not item.session_file then
        return false
      end
      local lines = parse_session_for_preview(item.session_file)
      vim.bo[ctx.buf].modifiable = true
      vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, lines)
      vim.bo[ctx.buf].filetype = "markdown"
      vim.bo[ctx.buf].modifiable = false
      return true
    end,
    confirm = function(picker, item)
      picker:close()
      if not item then
        return
      end
      -- Schedule both paths so the picker fully closes before we manipulate windows
      if item.kind == "running" and item.terminal_id then
        vim.schedule(function()
          M.switch_to(item.terminal_id)
        end)
      elseif item.kind == "inactive" and item.claude_session_id then
        vim.schedule(function()
          M.resume_session(item.claude_session_id, cwd)
        end)
      end
    end,
    actions = {
      kill_session = function(picker)
        local item = picker:current()
        if not item or item.kind ~= "running" or not item.terminal_id then
          return
        end
        M.kill_session(item.terminal_id)
        picker:close()
        vim.schedule(function()
          M.show_picker(cwd)
        end)
      end,
      new_session = function(picker)
        picker:close()
        vim.schedule(function()
          M.new_session()
        end)
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-d>"] = { "kill_session", desc = "Kill running session", mode = { "i", "n" } },
          ["<C-n>"] = { "new_session", desc = "New session", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["dd"] = { "kill_session", desc = "Kill running session", mode = "n" },
          ["n"] = { "new_session", desc = "New session", mode = "n" },
        },
      },
    },
  })
end

return M
