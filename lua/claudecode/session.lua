---@brief [[
--- Per-directory Claude session management.
--- Handles session listing, preference persistence, and picker UI.
---@brief ]]
---@module 'claudecode.session'

local M = {}

-- Module config (set via setup())
local config = { enabled = true }

-- In-memory: cwd paths where user chose "start fresh" this Neovim session
-- { [canonical_cwd] = true }
local skip_cwd = {}

-- Whether setup() has been called
M.is_setup = false

---Canonicalise a cwd path: resolve symlinks, ensure absolute, strip trailing slash.
---@param raw string Raw path (e.g. from vim.fn.getcwd())
---@return string canonical Normalised absolute path without trailing slash
function M._canonical_cwd(raw)
  local resolved = vim.fn.resolve(raw)
  local absolute = vim.fn.fnamemodify(resolved, ":p")
  return absolute:gsub("/$", "")
end

---Hash a canonical cwd to match Claude CLI's project directory naming.
---Claude replaces all '/' with '-' in the path.
---Note: this has a theoretical collision risk (e.g. /foo/bar vs /foo-bar)
---but is intentional — it must match Claude CLI's own convention.
---@param canonical string Canonical cwd from _canonical_cwd()
---@return string hash Directory name used by Claude CLI
function M._hash_cwd(canonical)
  return canonical:gsub("/", "-")
end

---Parse the last user message preview from a Claude session JSONL file.
---@param path string Absolute path to the .jsonl file
---@return string preview Up to 60 chars of the last user message, or "(no preview)"
function M._parse_session_preview(path)
  local file = io.open(path, "r")
  if not file then
    return "(no preview)"
  end

  local last_user_text = nil
  for line in file:lines() do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" and entry.type == "user" then
      local msg = entry.message
      if type(msg) == "table" and msg.role == "user" then
        local content = msg.content
        local text = nil
        if type(content) == "string" then
          text = content
        elseif type(content) == "table" then
          for _, c in ipairs(content) do
            if type(c) == "table" and c.type == "text" and type(c.text) == "string" then
              text = c.text
              break
            end
          end
        end
        if text and type(text) == "string" then
          -- Strip command message XML tags (Claude Code slash commands)
          text = text:gsub("<command%-message>.-</command%-message>", "")
          text = text:gsub("<command%-name>.-</command%-name>", "")
          text = text:match("^%s*(.-)%s*$") -- trim
          if text ~= "" then
            last_user_text = text
          end
        end
      end
    end
  end
  file:close()

  if not last_user_text then
    return "(no preview)"
  end

  if #last_user_text > 60 then
    return last_user_text:sub(1, 60) .. "..."
  end
  return last_user_text
end

---List all Claude sessions for a given cwd, sorted newest first.
---@param cwd string Raw cwd (will be canonicalised internally)
---@return table sessions Array of {id, timestamp, formatted} tables
function M._list_sessions(cwd)
  local canonical = M._canonical_cwd(cwd)
  local hash = M._hash_cwd(canonical)
  local projects_base = vim.fn.expand("~/.claude/projects/")
  local dir = projects_base .. hash .. "/"

  local handle = vim.loop.fs_opendir(dir, nil, 100)
  if not handle then
    return {}
  end

  -- fs_readdir is an iterator — loop until it returns nil to get all entries
  local entries = {}
  while true do
    local batch = vim.loop.fs_readdir(handle)
    if not batch then
      break
    end
    for _, e in ipairs(batch) do
      table.insert(entries, e)
    end
  end
  vim.loop.fs_closedir(handle)

  local sessions = {}
  for _, entry in ipairs(entries) do
    if entry.type == "file" and entry.name:match("%.jsonl$") then
      local id = entry.name:gsub("%.jsonl$", "")
      local full_path = dir .. entry.name
      local stat = vim.loop.fs_stat(full_path)
      if stat then -- intentional: guard against TOCTOU (file deleted between readdir and stat)
        local ts = stat.mtime.sec
        local preview = M._parse_session_preview(full_path)
        local date_str = os.date("%Y-%m-%d %H:%M", ts)
        table.insert(sessions, {
          id = id,
          timestamp = ts,
          preview = preview,
          formatted = date_str .. '  "' .. preview .. '"',
        })
      end
    end
  end

  table.sort(sessions, function(a, b)
    return a.timestamp > b.timestamp
  end)

  return sessions
end

-- Path to preferences file
local function get_prefs_path()
  return vim.fn.stdpath("data") .. "/claudecode/sessions.json"
end

---Read preferences from disk. Returns empty table on any error.
---@return table prefs Map of canonical_cwd -> { last_session_id, updated_at }
local function read_prefs()
  local path = get_prefs_path()
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  if not content or content == "" then
    return {}
  end
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

---Write preferences to disk atomically (temp file + rename).
---@param prefs table Map to persist
---@return boolean success
local function write_prefs(prefs)
  local path = get_prefs_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")

  local content = vim.json.encode(prefs)
  local tmp_path = path .. ".tmp"

  local fd = vim.loop.fs_open(tmp_path, "w", 438) -- 0666
  if not fd then
    local logger = require("claudecode.logger")
    logger.warn("session", "Failed to write session preferences: could not open " .. tmp_path)
    return false
  end
  vim.loop.fs_write(fd, content, 0)
  vim.loop.fs_close(fd)
  return vim.loop.fs_rename(tmp_path, path) ~= false
end

---Get the last saved session ID for the given cwd.
---@param cwd string Raw cwd path
---@return string|nil session_id UUID or nil if not saved
function M._get_last_session_id(cwd)
  local canonical = M._canonical_cwd(cwd)
  local prefs = read_prefs()
  local entry = prefs[canonical]
  if type(entry) == "table" then
    return entry.last_session_id
  end
  return nil
end

---Save the last session ID for the given cwd.
---@param cwd string Raw cwd path
---@param session_id string UUID to save
function M._save_last_session_id(cwd, session_id)
  local canonical = M._canonical_cwd(cwd)
  local prefs = read_prefs()
  prefs[canonical] = {
    last_session_id = session_id,
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  write_prefs(prefs)
end

---Configure the session module. Called from init.lua's M.setup().
---@param opts table { enabled: boolean }
function M.setup(opts)
  config = vim.tbl_deep_extend("force", { enabled = true }, opts or {})
  M.is_setup = true
end

---Clear all in-memory state. Called from init.lua's M.stop().
function M.reset()
  skip_cwd = {}
  M.is_setup = false
end

---Resolve which arguments to pass to claude for the given cwd.
---
---Calls callback(args) where:
---  args = nil          -> start fresh (or no sessions available)
---  args = "--resume X" -> resume session X
---  args = false        -> user cancelled; do NOT open terminal
---
---If no prompt is needed, callback is called synchronously.
---If a picker is shown, callback is called from vim.ui.select's callback.
---
---@param cwd string Raw cwd (e.g. from vim.fn.getcwd())
---@param callback function function(args: string|nil|false)
function M.resolve_args(cwd, callback)
  if not config.enabled then
    callback(nil)
    return
  end

  local canonical = M._canonical_cwd(cwd)

  -- Skip if user already chose "start fresh" this Neovim session
  if skip_cwd[canonical] then
    callback(nil)
    return
  end

  local sessions = M._list_sessions(cwd)
  local last_id = M._get_last_session_id(cwd)

  -- If no sessions and no last_id: open fresh silently, no prompt
  if #sessions == 0 and not last_id then
    callback(nil)
    return
  end

  -- Build picker options
  local options = {}
  local handlers = {}

  -- Option 1: Start fresh
  table.insert(options, "Start fresh (no session)")
  table.insert(handlers, function()
    skip_cwd[canonical] = true
    callback(nil)
  end)

  -- Option 2: Restore last session (only if we have a saved last_id)
  if last_id then
    local last_preview = "(unknown)"
    for _, s in ipairs(sessions) do
      if s.id == last_id then
        last_preview = s.formatted
        break
      end
    end
    table.insert(options, "Restore last session  (" .. last_preview .. ")")
    table.insert(handlers, function()
      M._save_last_session_id(cwd, last_id)
      callback("--resume " .. last_id)
    end)
  end

  -- Option 3: Choose session (only if there are sessions to choose from)
  if #sessions > 0 then
    table.insert(options, "Choose session...")
    table.insert(handlers, function()
      local session_labels = {}
      for _, s in ipairs(sessions) do
        table.insert(session_labels, s.formatted)
      end
      vim.ui.select(session_labels, { prompt = "Choose Claude session:" }, function(choice, idx)
        if not choice or not idx then
          callback(false)
          return
        end
        local selected = sessions[idx]
        M._save_last_session_id(cwd, selected.id)
        callback("--resume " .. selected.id)
      end)
    end)
  end

  vim.ui.select(options, { prompt = "Select Claude session:" }, function(choice, idx)
    if not choice or not idx then
      callback(false)
      return
    end
    handlers[idx]()
  end)
end

return M
