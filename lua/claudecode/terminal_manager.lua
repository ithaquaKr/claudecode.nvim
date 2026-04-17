---Multi-session terminal management for claudecode.nvim.
---Manages multiple running Claude CLI terminal sessions per working directory,
---with show/hide (background) support and a Snacks-based quick switcher.
---@module 'claudecode.terminal_manager'

local M = {}

---@class ClaudeSessionEntry
---@field id string Unique internal ID for this terminal session
---@field bufnr number Neovim buffer number
---@field jobid number Terminal job ID (from vim.fn.termopen)
---@field label string Display label (from Claude session file preview)
---@field cwd string Working directory this session was opened in
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

--- Show a buffer in a new split window using the configured split settings.
---@param bufnr number
local function show_in_split(bufnr)
  local side = _cfg.split_side or "right"
  local pct = _cfg.split_width_percentage or 0.30
  local width = math.floor(vim.o.columns * pct)
  local placement = (side == "right") and "botright" or "topleft"
  vim.cmd(placement .. " " .. width .. "vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(win, vim.o.lines)
  vim.api.nvim_win_set_buf(win, bufnr)
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

--- Derive a display label from the resolved session args.
--- Looks up the preview text from the Claude session JSONL file.
---@param resolved_args string|nil
---@param cwd string
---@return string
local function derive_label(resolved_args, cwd)
  if not resolved_args or resolved_args == "" then
    -- Count existing sessions for this cwd to give a number
    local n = #sessions_for_cwd(cwd) + 1
    return "New Session " .. n
  end

  local sid = resolved_args:match("--resume%s+(%S+)")
  if not sid then
    return "New Session"
  end

  local ok, session_module = pcall(require, "claudecode.session")
  if ok then
    local ok2, list = pcall(session_module._list_sessions, cwd)
    if ok2 and list then
      for _, se in ipairs(list) do
        if se.id == sid then
          local preview = (se.preview and se.preview ~= "(no preview)") and se.preview or nil
          if preview then
            -- Truncate long previews for display
            return #preview > 55 and (preview:sub(1, 52) .. "…") or preview
          end
          -- Fallback: show date + short id
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
--- After the user picks (fresh/resume/choose), a new terminal buffer is created
--- and becomes the active session. The previous active session is hidden.
function M.new_session()
  local ok, session_module = pcall(require, "claudecode.session")
  if not ok or not session_module.is_setup then
    -- Session module unavailable or not set up — just open a fresh terminal
    session_module = nil
  end

  local cwd = vim.fn.getcwd()

  local function open_terminal(resolved_args)
    local label = derive_label(resolved_args, cwd)
    local cmd, env = build_cmd_env(resolved_args)

    hide_active()

    local bufnr = vim.api.nvim_create_buf(false, true)
    show_in_split(bufnr)

    local session_id = gen_id()

    ---@type ClaudeSessionEntry
    local entry = {
      id = session_id,
      bufnr = bufnr,
      jobid = -1,
      label = label,
      cwd = cwd,
      status = "active",
      created_at = os.time(),
    }

    local jobid = vim.fn.termopen(cmd, {
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

    entry.jobid = jobid
    table.insert(sessions, entry)
    active_id = session_id

    vim.cmd("startinsert")
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

--- Switch to a session by its internal ID.
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
      show_in_split(s.bufnr)
      vim.cmd("startinsert")
    end
    return
  end

  hide_active()
  show_in_split(s.bufnr)
  s.status = "active"
  active_id = session_id
  vim.cmd("startinsert")
end

--- Kill (terminate and remove) a session by its internal ID.
--- If it was the active session, switches to the most recent live session or does nothing.
---@param session_id string
function M.kill_session(session_id)
  local s, idx = find_by_id(session_id)
  if not s then
    return
  end

  local was_active = (active_id == session_id)
  local prev_cwd = s.cwd

  -- Stop the process
  if s.jobid and s.jobid > 0 then
    pcall(vim.fn.jobstop, s.jobid)
  end
  -- Remove the buffer
  if vim.api.nvim_buf_is_valid(s.bufnr) then
    hide_buf_windows(s.bufnr)
    pcall(vim.api.nvim_buf_delete, s.bufnr, { force = true })
  end

  table.remove(sessions, idx)

  if was_active then
    active_id = nil
    -- Try to switch to the most-recent live session for same cwd
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
        show_in_split(s.bufnr)
        s.status = "active"
        vim.cmd("startinsert")
      end
      return
    end
    -- Active session went dead
    active_id = nil
  end

  -- Try to restore a background session for this cwd
  local cwd_sessions = sessions_for_cwd(cwd)
  for i = #cwd_sessions, 1, -1 do
    local s = cwd_sessions[i]
    if s.status == "background" and vim.api.nvim_buf_is_valid(s.bufnr) then
      M.switch_to(s.id)
      return
    end
  end

  -- No live session — open a new one
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
--- Displays all sessions with status indicators.
--- Keybindings inside the picker:
---   <CR>   — switch to selected session
---   dd     — kill selected session (normal mode)
---   <C-d>  — kill selected session (insert mode)
---   <C-n>  — open a new session and close the picker
---@param cwd string|nil Defaults to vim.fn.getcwd()
function M.show_picker(cwd)
  local ok, Snacks = pcall(require, "snacks")
  if not ok then
    vim.notify("claudecode: snacks.nvim is required for the session switcher", vim.log.levels.ERROR)
    return
  end

  cwd = cwd or vim.fn.getcwd()

  --- Build the item list for the picker.
  ---@return table[]
  local function build_items()
    local cwd_sessions = sessions_for_cwd(cwd)
    local items = {}
    for _, s in ipairs(cwd_sessions) do
      -- Status icon: ● active (visible window), ○ background (running), ✗ dead
      local icon
      if s.status == "active" then
        icon = "● "
      elseif s.status == "background" then
        icon = "○ "
      else
        icon = "✗ "
      end
      table.insert(items, {
        text = icon .. s.label,
        session_id = s.id,
        session_status = s.status,
      })
    end

    if #items == 0 then
      -- Show a hint when there are no sessions yet
      table.insert(items, {
        text = "  No sessions — press <C-n> to open one",
        session_id = nil,
      })
    end

    return items
  end

  Snacks.picker.pick({
    title = "Claude Code Sessions",
    items = build_items(),
    format = "text",
    confirm = function(picker, item)
      picker:close()
      if item and item.session_id then
        M.switch_to(item.session_id)
      end
    end,
    actions = {
      kill_session = function(picker)
        local item = picker:current()
        if not item or not item.session_id then
          return
        end
        M.kill_session(item.session_id)
        -- Reopen the picker with the updated list after a short delay
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
          ["<C-d>"] = { "kill_session", desc = "Kill session", mode = { "i", "n" } },
          ["<C-n>"] = { "new_session", desc = "New session", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["dd"] = { "kill_session", desc = "Kill session", mode = "n" },
          ["n"] = { "new_session", desc = "New session", mode = "n" },
        },
      },
    },
  })
end

return M
