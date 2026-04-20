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
---@field jobid number Terminal job ID (from vim.fn.termopen), -1 for snacks sessions
---@field label string Display label (Claude session preview or "New Session N")
---@field cwd string Working directory this session was opened in
---@field claude_session_id string|nil UUID of the Claude CLI session file, if known
---@field status "active"|"background"|"dead" Visibility/alive state
---@field created_at number Unix timestamp of creation
---@field last_attached_at number Unix timestamp of the last time this session became active
---@field _snacks_term table|nil Snacks terminal instance, when using snacks provider
---@field client_id string|nil WebSocket client ID of the connected Claude CLI process
---@field profile string|nil Profile name this session was opened with (nil = default_profile)

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

--- Return the current active/default profile name, or nil when profiles are not configured.
---@return string|nil
local function active_profile_name()
  local ok, mod = pcall(require, "claudecode.profiles")
  if ok and mod.has_profiles and mod.has_profiles() then
    return mod.get_active_name()
  end
  return nil
end

--- Find the best editor window to split from: non-floating, non-terminal.
--- Prefers the currently focused window so the split opens where the user expects.
--- Only falls back to searching when the current window is floating (e.g. a picker)
--- or is itself a terminal buffer.
---@return number winid
local function find_editor_win()
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(cur) then
    local cfg = vim.api.nvim_win_get_config(cur)
    if not cfg.relative or cfg.relative == "" then
      if vim.bo[vim.api.nvim_win_get_buf(cur)].buftype ~= "terminal" then
        return cur
      end
    end
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(w) then
      local cfg = vim.api.nvim_win_get_config(w)
      if not cfg.relative or cfg.relative == "" then
        if vim.bo[vim.api.nvim_win_get_buf(w)].buftype ~= "terminal" then
          return w
        end
      end
    end
  end
  return cur
end

--- Resolve split geometry from config.
---@return string placement, number width
local function split_params()
  local side = _cfg.split_side or "right"
  local pct = _cfg.split_width_percentage or 0.30
  return (side == "right") and "botright" or "topleft", math.floor(vim.o.columns * pct)
end

--- Redirect the current window to a proper editor window when needed.
--- Only acts if the current window is floating (e.g. a closed picker) or a terminal buffer.
--- Mirrors native.lua: splits from wherever the user is unless that's impossible.
local function ensure_editor_win()
  local cur = vim.api.nvim_get_current_win()
  local cfg = vim.api.nvim_win_get_config(cur)
  local is_float = cfg.relative and cfg.relative ~= ""
  local is_term = vim.bo[vim.api.nvim_win_get_buf(cur)].buftype == "terminal"
  if is_float or is_term then
    vim.api.nvim_set_current_win(find_editor_win())
  end
end

--- Spawn a new Claude terminal session.
--- Uses Snacks.terminal.open when available (creates a proper side panel that
--- navigation plugins like vim-tmux-navigator understand). Falls back to a plain
--- vsplit + termopen when snacks is not installed.
---@param cmd_string string Full Claude CLI command string
---@param env table Environment variables
---@param label string Display label
---@param cwd string Working directory
---@param claude_session_id string|nil Claude CLI session UUID
---@param profile string|nil Profile name this session is opened with
local function open_new_terminal(cmd_string, env, label, cwd, claude_session_id, profile)
  local session_id = gen_id()
  ---@type ClaudeSessionEntry
  local entry = {
    id = session_id,
    bufnr = -1,
    jobid = -1,
    label = label,
    cwd = cwd,
    claude_session_id = claude_session_id,
    status = "active",
    created_at = os.time(),
    last_attached_at = os.time(),
    _snacks_term = nil,
    client_id = nil,
    profile = profile,
  }

  local snacks_ok, Snacks = pcall(require, "snacks")
  if snacks_ok and Snacks and Snacks.terminal then
    -- Use Snacks.terminal.open so the window is a proper Snacks side panel —
    -- this matches what the old provider created and is what navigation plugins expect.
    local side = _cfg.split_side or "right"
    local opts = {
      env = env,
      cwd = cwd,
      start_insert = true,
      auto_insert = true,
      auto_close = false, -- we handle cleanup ourselves
      win = vim.tbl_deep_extend("force", {
        position = side,
        width = _cfg.split_width_percentage or 0.30,
        height = 0,
        relative = "editor",
      }, (_cfg.snacks_win_opts or {})),
    }

    local term_instance = Snacks.terminal.open(cmd_string, opts)
    if not term_instance or not term_instance:buf_valid() then
      vim.notify("claudecode: failed to open snacks terminal", vim.log.levels.ERROR)
      return
    end

    entry.bufnr = term_instance.buf
    entry._snacks_term = term_instance

    -- Mark dead on process exit
    term_instance:on("TermClose", function()
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
          pcall(function()
            term_instance:close({ buf = true })
          end)
        end
      end)
    end, { buf = true })

    term_instance:on("BufWipeout", function()
      local s = find_by_id(session_id)
      if s then
        s.status = "dead"
        if active_id == session_id then
          active_id = nil
        end
      end
    end, { buf = true })

    table.insert(sessions, entry)
    active_id = session_id
    return
  end

  -- Native vsplit fallback (mirrors native.lua's open_terminal)
  ensure_editor_win()
  local original_win = vim.api.nvim_get_current_win()
  local placement, width = split_params()

  vim.cmd(placement .. " " .. width .. "vsplit")
  local new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_win, vim.o.lines)

  vim.api.nvim_win_call(new_win, function()
    vim.cmd("enew")
  end)

  local cmd_arg = cmd_string:find(" ", 1, true)
    and vim.split(cmd_string, " ", { plain = true, trimempty = false })
    or { cmd_string }

  local jobid = vim.fn.termopen(cmd_arg, {
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
    vim.notify("claudecode: failed to start claude process", vim.log.levels.ERROR)
    vim.api.nvim_set_current_win(original_win)
    return
  end

  -- Read buffer after termopen — termopen may allocate a new buf (mirrors native.lua)
  entry.bufnr = vim.api.nvim_get_current_buf()
  entry.jobid = jobid
  vim.bo[entry.bufnr].bufhidden = "hide"
  table.insert(sessions, entry)
  active_id = session_id

  vim.api.nvim_set_current_win(new_win)
  -- Defer startinsert so any typeahead queued before the terminal opens is flushed first
  vim.schedule(function()
    vim.cmd("startinsert")
  end)
end

--- Show an existing session buffer.
--- For snacks sessions: uses the snacks term instance to show/focus.
--- For native sessions: splits from the user's current window and sets the buffer.
--- Does NOT enter insert mode — callers handle startinsert after this.
---@param s ClaudeSessionEntry
---@return number new_win
local function show_existing_terminal(s)
  if s._snacks_term then
    if not s._snacks_term:win_valid() then
      s._snacks_term:toggle() -- show the hidden window
    end
    s._snacks_term:focus()
    return s._snacks_term.win or vim.api.nvim_get_current_win()
  end

  -- Native vsplit fallback
  ensure_editor_win()
  local placement, width = split_params()

  vim.cmd(placement .. " " .. width .. "vsplit")
  local new_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_win, vim.o.lines)
  vim.api.nvim_win_set_buf(new_win, s.bufnr)
  return new_win
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
--- Shows conversation history with a metadata header and clean turn formatting.
---@param session_file string Absolute path to the .jsonl file
---@param session_status string|nil "active"|"background"|"dead"|"inactive"
---@return string[]
local function parse_session_for_preview(session_file, session_status)
  local file = io.open(session_file, "r")
  if not file then
    return { "  (could not open session file)" }
  end

  -- Tail-read for performance on large sessions
  local raw_lines = {}
  for line in file:lines() do
    table.insert(raw_lines, line)
  end
  file:close()

  local stat = vim.loop.fs_stat(session_file)
  local date_str = stat and os.date("%Y-%m-%d  %H:%M", stat.mtime.sec) or ""

  local start_idx = math.max(1, #raw_lines - 400)
  local turns = {}

  for i = start_idx, #raw_lines do
    local ok, entry = pcall(vim.json.decode, raw_lines[i])
    if ok and type(entry) == "table" then
      local role = entry.type
      if (role == "user" or role == "assistant") and type(entry.message) == "table" then
        local text = extract_text_from_content(entry.message.content)
        text = text:gsub("<command%-message>.-</command%-message>", "")
        text = text:gsub("<command%-name>.-</command%-name>", "")
        text = text:match("^%s*(.-)%s*$") or text
        if text ~= "" then
          table.insert(turns, { role = role, text = text })
        end
      end
    end
  end

  local lines = {}

  -- Header bar
  local badge
  if session_status == "active" then
    badge = "● LIVE"
  elseif session_status == "background" then
    badge = "○ BG"
  elseif session_status == "dead" then
    badge = "✕ DEAD"
  else
    badge = "  HISTORY"
  end
  local turn_word = #turns == 1 and "turn" or "turns"
  table.insert(lines, "  " .. badge .. "  ·  " .. date_str .. "  ·  " .. #turns .. " " .. turn_word)
  table.insert(lines, "  " .. string.rep("═", 50))
  table.insert(lines, "")

  if #turns == 0 then
    table.insert(lines, "  (no conversation content found)")
    return lines
  end

  -- Show the last 12 turns (6 exchanges)
  local show_from = math.max(1, #turns - 11)
  if show_from > 1 then
    table.insert(lines, "  ‹ " .. (show_from - 1) .. " earlier turns ›")
    table.insert(lines, "")
  end

  local function add_content_lines(text, max_chars)
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
      if #l > max_chars then
        table.insert(lines, "  │ " .. l:sub(1, max_chars - 1) .. "…")
      else
        table.insert(lines, "  │ " .. l)
      end
    end
  end

  for i = show_from, #turns do
    local turn = turns[i]
    if turn.role == "user" then
      table.insert(lines, "  ▸ you " .. string.rep("─", 44))
      local text = #turn.text > 400 and (turn.text:sub(1, 397) .. "…") or turn.text
      add_content_lines(text, 58)
    else
      table.insert(lines, "  ▸ claude " .. string.rep("─", 41))
      local text = #turn.text > 600 and (turn.text:sub(1, 597) .. "…") or turn.text
      add_content_lines(text, 58)
    end
    table.insert(lines, "")
  end

  return lines
end

--- Build claude command string and environment table.
---@param resolved_args string|nil Args from session picker (e.g. "--resume UUID")
---@param profile_name string|nil Profile to use (nil = active/default profile)
---@return string cmd, table env
local function build_cmd_env(resolved_args, profile_name)
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
  -- Global config env (base layer)
  for k, v in pairs(_cfg.env or {}) do
    env[k] = v
  end
  -- Per-session profile env overrides global config (includes CLAUDE_CONFIG_DIR when set)
  local profiles_ok, profiles_module = pcall(require, "claudecode.profiles")
  if profiles_ok and profiles_module.has_profiles and profiles_module.has_profiles() then
    for k, v in pairs(profiles_module.get_profile_env(profile_name)) do
      env[k] = v
    end
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


--- Delete the Claude CLI session JSONL file from disk.
---@param claude_session_id string Session UUID
---@param cwd string Working directory the session belongs to
---@param profile_name string|nil Profile the session belongs to (nil = active/default)
---@return boolean deleted
local function delete_claude_session_file(claude_session_id, cwd, profile_name)
  if not claude_session_id or claude_session_id == "" then
    return false
  end
  local ok, session_module = pcall(require, "claudecode.session")
  if not ok then
    return false
  end
  local ok_c, canonical = pcall(session_module._canonical_cwd, cwd)
  if not ok_c then
    return false
  end
  local ok_h, hash = pcall(session_module._hash_cwd, canonical)
  if not ok_h then
    return false
  end
  local projects_base = vim.fn.expand("~/.claude/projects/")
  local profiles_ok, profiles_module = pcall(require, "claudecode.profiles")
  if profiles_ok and profiles_module.has_profiles and profiles_module.has_profiles() then
    projects_base = profiles_module.get_projects_dir(profile_name)
  end
  local path = projects_base .. hash .. "/" .. claude_session_id .. ".jsonl"
  return vim.loop.fs_unlink(path) == true
end

--- Hide the currently active session's window (keeps process running).
local function hide_active()
  if not active_id then
    return
  end
  local s = find_by_id(active_id)
  if s and vim.api.nvim_buf_is_valid(s.bufnr) then
    if s._snacks_term then
      if s._snacks_term:win_valid() then
        s._snacks_term:toggle() -- hides the snacks panel
      end
    else
      hide_buf_windows(s.bufnr)
    end
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

--- Called by the WebSocket server when a new Claude CLI client connects.
--- Assigns the client to the oldest unassigned live session, then tells the
--- server which client is "active" if the session is the current active one.
---@param client_id string WebSocket client ID
function M.on_client_connect(client_id)
  -- Find the oldest live session without a client_id yet (FIFO assignment)
  local oldest = nil
  for _, s in ipairs(sessions) do
    if s.status ~= "dead" and not s.client_id then
      if not oldest or s.created_at < oldest.created_at then
        oldest = s
      end
    end
  end

  if not oldest then
    return
  end

  oldest.client_id = client_id

  -- If this session is the active one, update the server's active client
  if oldest.id == active_id then
    local ok, server = pcall(require, "claudecode.server.init")
    if ok then
      server.set_active_client(client_id)
    end
  end
end

--- Tell the server which client belongs to the given session (if known).
---@param session ClaudeSessionEntry
local function sync_active_client(session)
  if session and session.client_id then
    local ok, server = pcall(require, "claudecode.server.init")
    if ok then
      server.set_active_client(session.client_id)
    end
  end
end

--- Open a brand-new Claude session directly — no session picker.
--- Session history browsing is done exclusively via show_picker().
--- Hides the current active session and spawns a fresh terminal.
---@param forced_args string|nil Optional extra CLI args (e.g. "--verbose")
function M.new_session(forced_args)
  local profile = active_profile_name()
  local cwd = vim.fn.getcwd()
  local label = derive_label(forced_args, cwd)
  local cmd, env = build_cmd_env(forced_args, profile)
  hide_active()
  open_new_terminal(cmd, env, label, cwd, nil, profile)
end

--- Open a new Claude terminal session bound to a specific profile.
--- The Claude CLI process is launched with the profile's CLAUDE_CONFIG_DIR so it
--- uses the correct account credentials, independent of the current default profile.
---@param profile_name string The profile to use for this session
function M.new_session_with_profile(profile_name)
  local cwd = vim.fn.getcwd()
  local label = derive_label(nil, cwd)
  local cmd, env = build_cmd_env(nil, profile_name)
  hide_active()
  open_new_terminal(cmd, env, label, cwd, nil, profile_name)
end

--- Resume a specific Claude CLI session by its UUID, bypassing the session picker.
--- If a terminal for that session is already running, switch to it instead.
---@param claude_session_id string The Claude CLI session UUID to resume
---@param cwd string|nil Working directory (defaults to vim.fn.getcwd())
---@param profile_name string|nil Profile the session belongs to (nil = active default)
function M.resume_session(claude_session_id, cwd, profile_name)
  cwd = cwd or vim.fn.getcwd()

  -- If there's already a live terminal for this Claude session, just switch to it
  for _, s in ipairs(sessions_for_cwd(cwd)) do
    if s.claude_session_id == claude_session_id and s.status ~= "dead" then
      M.switch_to(s.id)
      return
    end
  end

  -- No running terminal — open a new one resuming this session using the correct profile
  local profile = profile_name or active_profile_name()
  local resolved_args = "--resume " .. claude_session_id
  local label = derive_label(resolved_args, cwd)
  local cmd, env = build_cmd_env(resolved_args, profile)

  hide_active()
  open_new_terminal(cmd, env, label, cwd, claude_session_id, profile)
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
    if not is_buf_visible(s.bufnr) then
      show_existing_terminal(s)
      vim.schedule(function()
        vim.cmd("startinsert")
      end)
    end
    return
  end

  hide_active()
  show_existing_terminal(s)
  s.status = "active"
  s.last_attached_at = os.time()
  active_id = session_id
  sync_active_client(s)
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

  if s._snacks_term then
    pcall(function()
      s._snacks_term:close({ buf = true })
    end)
  else
    if s.jobid and s.jobid > 0 then
      pcall(vim.fn.jobstop, s.jobid)
    end
    if vim.api.nvim_buf_is_valid(s.bufnr) then
      hide_buf_windows(s.bufnr)
      pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
    end
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
--- If no sessions exist for the current cwd, spawns a fresh one immediately —
--- no session picker, matching the old single-session toggle behaviour exactly.
--- The session picker is only shown by new_session() (ClaudeCodeSessionNew).
function M.toggle()
  local cwd = vim.fn.getcwd()

  if active_id then
    local s = find_by_id(active_id)
    if s and s.status ~= "dead" and vim.api.nvim_buf_is_valid(s.bufnr) then
      if is_buf_visible(s.bufnr) then
        hide_active()
      else
        show_existing_terminal(s)
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
      show_existing_terminal(s)
      s.status = "active"
      active_id = s.id
      vim.schedule(function()
        vim.cmd("startinsert")
      end)
      return
    end
  end

  -- No active or background session — open a fresh one directly, no picker
  local profile = active_profile_name()
  local cmd, env = build_cmd_env(nil, profile)
  local label = derive_label(nil, cwd)
  open_new_terminal(cmd, env, label, cwd, nil, profile)
end

--- Open / show-and-focus the active session. Never hides it.
--- Equivalent to "open terminal and enter insert mode":
---   • visible + focused  → do nothing (already there)
---   • visible + unfocused → focus it
---   • hidden             → show and focus
---   • no session         → create one
--- Used by focus_after_send=true.
function M.open()
  if active_id then
    local s = find_by_id(active_id)
    if s and s.status ~= "dead" and vim.api.nvim_buf_is_valid(s.bufnr) then
      sync_active_client(s)
      if is_buf_visible(s.bufnr) then
        show_existing_terminal(s)
        vim.schedule(function()
          vim.cmd("startinsert")
        end)
      else
        show_existing_terminal(s)
        s.status = "active"
        vim.schedule(function()
          vim.cmd("startinsert")
        end)
      end
      return
    end
    active_id = nil
  end

  -- Try to restore a background session with focus
  local cwd = vim.fn.getcwd()
  for _, s in ipairs(sessions_for_cwd(cwd)) do
    if s.status == "background" and vim.api.nvim_buf_is_valid(s.bufnr) then
      show_existing_terminal(s)
      s.status = "active"
      active_id = s.id
      sync_active_client(s)
      vim.schedule(function()
        vim.cmd("startinsert")
      end)
      return
    end
  end

  -- No session — create one
  local profile = active_profile_name()
  local cmd, env = build_cmd_env(nil, profile)
  local label = derive_label(nil, cwd)
  open_new_terminal(cmd, env, label, cwd, nil, profile)
end

--- Show the active session without stealing focus or entering insert mode.
--- If no session is active, opens a new one (background, no focus steal).
--- Used by focus_after_send=false and similar "keep editing" paths.
function M.ensure_visible()
  if active_id then
    local s = find_by_id(active_id)
    if s and s.status ~= "dead" and vim.api.nvim_buf_is_valid(s.bufnr) then
      if not is_buf_visible(s.bufnr) then
        -- Show without focus: open the split, then return to the original window
        local orig = vim.api.nvim_get_current_win()
        show_existing_terminal(s)
        s.status = "active"
        vim.api.nvim_set_current_win(orig)
      end
      return
    end
    active_id = nil
  end

  -- Try to restore a background session without stealing focus
  local cwd = vim.fn.getcwd()
  for _, s in ipairs(sessions_for_cwd(cwd)) do
    if s.status == "background" and vim.api.nvim_buf_is_valid(s.bufnr) then
      local orig = vim.api.nvim_get_current_win()
      show_existing_terminal(s)
      s.status = "active"
      active_id = s.id
      vim.api.nvim_set_current_win(orig)
      return
    end
  end

  -- No session — create one but stay focused on the current window
  local orig = vim.api.nvim_get_current_win()
  local profile = active_profile_name()
  local cmd, env = build_cmd_env(nil, profile)
  local label = derive_label(nil, cwd)
  open_new_terminal(cmd, env, label, cwd, nil, profile)
  -- open_new_terminal enters insert mode via vim.schedule; override to stay on orig
  vim.schedule(function()
    vim.api.nvim_set_current_win(orig)
  end)
end

--- Hide the active session window without killing the process.
--- No-op if nothing is active or the window is already hidden.
function M.hide()
  if not active_id then
    return
  end
  local s = find_by_id(active_id)
  if s and is_buf_visible(s.bufnr) then
    hide_active()
  end
end

--- Focus-toggle: if the active session is focused, hide it; if visible but
--- unfocused, move focus to it; if hidden, show it; if nothing active, open new.
function M.focus_toggle()
  if active_id then
    local s = find_by_id(active_id)
    if s and s.status ~= "dead" and vim.api.nvim_buf_is_valid(s.bufnr) then
      if is_buf_visible(s.bufnr) then
        local cur_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
        if cur_buf == s.bufnr then
          hide_active()
        else
          local info = vim.fn.getbufinfo(s.bufnr)
          if info and #info > 0 and #info[1].windows > 0 then
            vim.api.nvim_set_current_win(info[1].windows[1])
          end
        end
      else
        show_existing_terminal(s)
        s.status = "active"
        vim.schedule(function()
          vim.cmd("startinsert")
        end)
      end
      return
    end
    active_id = nil
  end
  -- No active session — open fresh directly, no picker
  local cwd = vim.fn.getcwd()
  local profile = active_profile_name()
  local cmd, env = build_cmd_env(nil, profile)
  local label = derive_label(nil, cwd)
  open_new_terminal(cmd, env, label, cwd, nil, profile)
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

  local profiles_ok, profiles_module = pcall(require, "claudecode.profiles")
  local has_profiles = profiles_ok and profiles_module.has_profiles and profiles_module.has_profiles()
  local current_profile = has_profiles and profiles_module.get_active_name() or nil

  --- Resolve session_dir for a given projects_base + cwd hash.
  ---@param projects_base string
  ---@return string|nil
  local function resolve_session_dir(projects_base)
    local session_ok2, session_module2 = pcall(require, "claudecode.session")
    if not session_ok2 then
      return nil
    end
    local ok_c, canonical = pcall(session_module2._canonical_cwd, cwd)
    if not ok_c then
      return nil
    end
    local ok_h, hash = pcall(session_module2._hash_cwd, canonical)
    if not ok_h then
      return nil
    end
    return projects_base .. hash .. "/"
  end

  --- Format a Unix timestamp into a compact, human-readable age string.
  --- < 1 hour  → "5m ago"
  --- same day  → "14:32"
  --- this year → "Apr 20"
  --- older     → "2024 Apr 20"
  ---@param ts number Unix timestamp
  ---@return string
  local function format_item_time(ts)
    local now = os.time()
    local diff = now - ts
    if diff < 3600 then
      local mins = math.max(1, math.floor(diff / 60))
      return mins .. "m ago"
    end
    local t = os.date("*t", ts)
    local today = os.date("*t", now)
    if t.year == today.year and t.month == today.month and t.day == today.day then
      return os.date("%H:%M", ts)
    end
    if t.year == today.year then
      return os.date("%b %d", ts)
    end
    return os.date("%Y %b %d", ts)
  end

  --- Build merged item list from running terminals + Claude CLI session files.
  --- With profiles configured, merges sessions from all profiles, tagged by profile name.
  --- Each item includes a `session_file` path so the preview function can read it.
  ---@return table[]
  local function build_items()
    local items = {}
    local session_ok, session_module = pcall(require, "claudecode.session")

    --- Add items for one profile (or the default config when profile_name is nil).
    ---@param profile_name string|nil
    local function add_profile_items(profile_name)
      local prefix = has_profiles and ("[" .. (profile_name or "default") .. "] ") or ""

      local projects_base
      if has_profiles and profile_name then
        projects_base = profiles_module.get_projects_dir(profile_name)
      else
        local env_dir = os.getenv("CLAUDE_CONFIG_DIR")
        if env_dir and env_dir ~= "" then
          projects_base = vim.fn.expand(env_dir) .. "/projects/"
        else
          projects_base = vim.fn.expand("~/.claude/projects/")
        end
      end

      local session_dir = resolve_session_dir(projects_base)

      -- Pre-load all disk sessions so we can match anonymous running terminals
      local claude_sessions = {}
      if session_ok then
        local ok2, cs_list = pcall(session_module._list_sessions, cwd, projects_base)
        if ok2 and cs_list then
          claude_sessions = cs_list
        end
      end

      -- Running terminals whose stored profile matches this profile_name
      local running_by_claude_id = {}
      for _, s in ipairs(sessions_for_cwd(cwd)) do
        if s.profile == profile_name and s.claude_session_id then
          running_by_claude_id[s.claude_session_id] = s
        end
      end

      -- Anonymous running sessions (no claude_session_id yet).
      -- Try to match each to a recently-created JSONL (timestamp >= session start).
      -- On match, update the session entry so resume and future picker calls work correctly.
      -- Track matched JSONL ids so the disk-session loop below doesn't duplicate them.
      local claimed_by_anon = {}
      for _, s in ipairs(sessions_for_cwd(cwd)) do
        if s.profile == profile_name and not s.claude_session_id then
          local matched_cs = nil
          for _, cs in ipairs(claude_sessions) do
            if cs.timestamp >= s.created_at and not running_by_claude_id[cs.id] then
              matched_cs = cs
              s.claude_session_id = cs.id
              running_by_claude_id[cs.id] = s
              claimed_by_anon[cs.id] = true
              break
            end
          end

          local icon = s.status == "active" and "● " or (s.status == "background" and "○ " or "✕ ")
          local preview_text = matched_cs
            and (matched_cs.preview ~= "(no preview)" and matched_cs.preview or nil)
          local label = preview_text
            and (#preview_text > 40 and preview_text:sub(1, 37) .. "…" or preview_text)
            or s.label
          local ts = matched_cs and matched_cs.timestamp or s.created_at
          local time_str = format_item_time(ts)
          table.insert(items, {
            text = icon .. prefix .. time_str .. "  · " .. label,
            kind = "running",
            terminal_id = s.id,
            claude_session_id = s.claude_session_id,
            session_status = s.status,
            session_file = matched_cs and session_dir and (session_dir .. matched_cs.id .. ".jsonl") or nil,
            profile_name = profile_name,
            timestamp = ts,
          })
        end
      end

      -- Sessions from disk, annotated with live status when a terminal is running for them.
      -- Skip entries already represented by an anonymous running session item above.
      for _, cs in ipairs(claude_sessions) do
        if not claimed_by_anon[cs.id] then
          local running = running_by_claude_id[cs.id]
          local icon, kind, status
          if running then
            icon = running.status == "active" and "● "
              or (running.status == "background" and "○ " or "✕ ")
            kind = "running"
            status = running.status
          else
            icon = "· "
            kind = "inactive"
            status = "inactive"
          end
          local preview_text = (cs.preview and cs.preview ~= "(no preview)") and cs.preview
            or cs.id:sub(1, 8) .. "…"
          local label = #preview_text > 40 and (preview_text:sub(1, 37) .. "…") or preview_text
          local time_str = format_item_time(cs.timestamp)
          table.insert(items, {
            text = icon .. prefix .. time_str .. "  · " .. label,
            kind = kind,
            terminal_id = running and running.id or nil,
            claude_session_id = cs.id,
            session_status = status,
            session_file = session_dir and (session_dir .. cs.id .. ".jsonl") or nil,
            profile_name = profile_name,
            timestamp = cs.timestamp,
          })
        end
      end
    end

    if has_profiles then
      -- Active session's profile first (may differ from default when opened via SessionFor),
      -- then remaining profiles sorted by name, then nil/default last.
      local lead_profile = current_profile
      if active_id then
        local active_s = find_by_id(active_id)
        if active_s and active_s.profile then
          lead_profile = active_s.profile
        end
      end
      add_profile_items(lead_profile)
      for _, p in ipairs(profiles_module.get_all_profiles()) do
        if p.name ~= lead_profile then
          add_profile_items(p.name)
        end
      end
    else
      add_profile_items(nil)
    end

    if #items == 0 then
      table.insert(items, {
        text = "· No sessions — press <C-n> to open one",
        kind = "hint",
        session_file = nil,
      })
    end

    -- Sort: active first, then background by last_attached_at desc, then rest.
    -- When group_by_profile=false (default): dead/inactive sorted by timestamp desc (pure recency).
    -- When group_by_profile=true: dead/inactive keep profile-grouped insertion order.
    local group_by_profile = _cfg.group_by_profile == true
    local function item_sort_key(item)
      if item.session_status == "active" then
        return 0
      elseif item.session_status == "background" then
        return 1
      else
        return 2
      end
    end
    for i, item in ipairs(items) do
      item._order = i
    end
    table.sort(items, function(a, b)
      local ka, kb = item_sort_key(a), item_sort_key(b)
      if ka ~= kb then
        return ka < kb
      end
      if ka == 1 then
        -- Both background: most recently attached first
        local sa = a.terminal_id and find_by_id(a.terminal_id)
        local sb = b.terminal_id and find_by_id(b.terminal_id)
        local ta = sa and (sa.last_attached_at or sa.created_at) or 0
        local tb = sb and (sb.last_attached_at or sb.created_at) or 0
        if ta ~= tb then
          return ta > tb
        end
      elseif ka == 2 and not group_by_profile then
        -- Both dead/inactive: most recently modified first (pure recency, cross-profile)
        local ta = a.timestamp or 0
        local tb = b.timestamp or 0
        if ta ~= tb then
          return ta > tb
        end
      end
      return a._order < b._order
    end)

    return items
  end

  local picker_title = "Claude Code Sessions"
  if has_profiles and current_profile then
    picker_title = picker_title .. "  [default: " .. current_profile .. "]"
  end

  Snacks.picker.pick({
    title = picker_title,
    items = build_items(),
    format = "text",
    preview = function(ctx)
      local item = ctx.item
      if not item then
        return false
      end

      local preview_lines

      if item.session_file then
        preview_lines = parse_session_for_preview(item.session_file, item.session_status)
      elseif item.kind == "running" and item.terminal_id then
        -- Running session with no JSONL yet (fresh, never saved a turn)
        local s = find_by_id(item.terminal_id)
        local status_badge = item.session_status == "active" and "● LIVE" or "○ BG"
        preview_lines = {
          "  " .. status_badge .. "  ·  " .. os.date("%Y-%m-%d  %H:%M", s and s.created_at or os.time()),
          "  " .. string.rep("═", 50),
          "",
          "  ▸ session info " .. string.rep("─", 35),
          "  │ Started:  " .. (s and os.date("%H:%M:%S", s.created_at) or "unknown"),
          "  │ CWD:      " .. (s and s.cwd or cwd),
          "",
          "  No conversation history yet.",
        }
      else
        return false
      end

      vim.bo[ctx.buf].modifiable = true
      vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, preview_lines)
      vim.bo[ctx.buf].filetype = "markdown"
      vim.bo[ctx.buf].modifiable = false
      return true
    end,
    confirm = function(picker, item)
      picker:close()
      if not item then
        return
      end

      if item.kind == "running" and item.terminal_id then
        vim.schedule(function()
          M.switch_to(item.terminal_id)
        end)
      elseif item.kind == "inactive" and item.claude_session_id then
        vim.schedule(function()
          M.resume_session(item.claude_session_id, cwd, item.profile_name)
        end)
      end
    end,
    actions = {
      -- Delete: kill terminal if running + remove JSONL from disk
      delete_session = function(picker)
        local item = picker:current()
        if not item or item.kind == "hint" then
          return
        end
        if item.kind == "running" and item.terminal_id then
          M.kill_session(item.terminal_id)
        end
        if item.claude_session_id then
          delete_claude_session_file(item.claude_session_id, cwd, item.profile_name)
        end
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
          ["<C-d>"] = { "delete_session", desc = "Delete session", mode = { "i", "n" } },
          ["<C-n>"] = { "new_session", desc = "New session", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["dd"] = { "delete_session", desc = "Delete session", mode = "n" },
          ["n"] = { "new_session", desc = "New session", mode = "n" },
        },
      },
    },
  })
end

return M
