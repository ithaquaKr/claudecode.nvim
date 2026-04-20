---@brief [[
--- Lock file management for Claude Code Neovim integration.
--- This module handles creation, removal and updating of lock files
--- which allow Claude Code CLI to discover the Neovim integration.
---@brief ]]
---@module 'claudecode.lockfile'
local M = {}

---Resolve the IDE lock-files directory, respecting the active profile when set.
---Always called at runtime so profile switches are reflected immediately.
---@return string lock_dir The path to the lock file directory
local function get_lock_dir()
  local profiles_ok, profiles_module = pcall(require, "claudecode.profiles")
  if profiles_ok and profiles_module.has_profiles and profiles_module.has_profiles() then
    return profiles_module.get_lock_dir()
  end
  local claude_config_dir = os.getenv("CLAUDE_CONFIG_DIR")
  if claude_config_dir and claude_config_dir ~= "" then
    return vim.fn.expand(claude_config_dir .. "/ide")
  else
    return vim.fn.expand("~/.claude/ide")
  end
end

M.get_lock_dir = get_lock_dir
-- Kept for backward compat; reflects state at load time, use get_lock_dir() for current value.
M.lock_dir = get_lock_dir()

---Return the lock-file directories for every configured profile.
---When no profiles are configured, returns the single default lock dir.
---@return string[] dirs
function M.get_all_lock_dirs()
  local profiles_ok, profiles_module = pcall(require, "claudecode.profiles")
  if profiles_ok and profiles_module.has_profiles and profiles_module.has_profiles() then
    local dirs = {}
    local seen = {}
    for _, p in ipairs(profiles_module.get_all_profiles()) do
      local dir = profiles_module.get_lock_dir(p.name)
      if not seen[dir] then
        seen[dir] = true
        table.insert(dirs, dir)
      end
    end
    if #dirs > 0 then
      return dirs
    end
  end
  return { get_lock_dir() }
end

-- Track if random seed has been initialized
local random_initialized = false

---Generate a random UUID for authentication
---@return string uuid A randomly generated UUID string
local function generate_auth_token()
  -- Initialize random seed only once
  if not random_initialized then
    local seed = os.time() + vim.fn.getpid()
    -- Add more entropy if available
    if vim.loop and vim.loop.hrtime then
      seed = seed + (vim.loop.hrtime() % 1000000)
    end
    math.randomseed(seed)

    -- Call math.random a few times to "warm up" the generator
    for _ = 1, 10 do
      math.random()
    end
    random_initialized = true
  end

  -- Generate UUID v4 format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  local uuid = template:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)

  -- Validate generated UUID format
  if not uuid:match("^[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+-[0-9a-f]+$") then
    error("Generated invalid UUID format: " .. uuid)
  end

  if #uuid ~= 36 then
    error("Generated UUID has invalid length: " .. #uuid .. " (expected 36)")
  end

  return uuid
end

---Generate a new authentication token
---@return string auth_token A newly generated authentication token
function M.generate_auth_token()
  return generate_auth_token()
end

---Create the lock file for a specified WebSocket port
---@param port number The port number for the WebSocket server
---@param auth_token? string Optional pre-generated auth token (generates new one if not provided)
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
---@return string? auth_token The authentication token if successful
function M.create(port, auth_token)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  if port < 1 or port > 65535 then
    return false, "Port number out of valid range (1-65535): " .. tostring(port)
  end

  local lock_dir = get_lock_dir()
  local ok, err = pcall(function()
    return vim.fn.mkdir(lock_dir, "p")
  end)

  if not ok then
    return false, "Failed to create lock directory: " .. (err or "unknown error")
  end

  local lock_path = lock_dir .. "/" .. port .. ".lock"

  local workspace_folders = M.get_workspace_folders()
  if not auth_token then
    local auth_success, auth_result = pcall(generate_auth_token)
    if not auth_success then
      return false, "Failed to generate authentication token: " .. (auth_result or "unknown error")
    end
    auth_token = auth_result
  else
    -- Validate provided auth_token
    if type(auth_token) ~= "string" then
      return false, "Authentication token must be a string, got " .. type(auth_token)
    end
    if #auth_token < 10 then
      return false, "Authentication token too short (minimum 10 characters)"
    end
    if #auth_token > 500 then
      return false, "Authentication token too long (maximum 500 characters)"
    end
  end

  -- Prepare lock file content
  local lock_content = {
    pid = vim.fn.getpid(),
    workspaceFolders = workspace_folders,
    ideName = "Neovim",
    transport = "ws",
    authToken = auth_token,
  }

  local json
  local ok_json, json_err = pcall(function()
    json = vim.json.encode(lock_content)
    return json
  end)

  if not ok_json or not json then
    return false, "Failed to encode lock file content: " .. (json_err or "unknown error")
  end

  local file = io.open(lock_path, "w")
  if not file then
    return false, "Failed to create lock file: " .. lock_path
  end

  local write_ok, write_err = pcall(function()
    file:write(json)
    file:close()
  end)

  if not write_ok then
    pcall(function()
      file:close()
    end)
    return false, "Failed to write lock file: " .. (write_err or "unknown error")
  end

  return true, lock_path, auth_token
end

---Remove the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string? error Error message if operation failed
function M.remove(port)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  local lock_path = get_lock_dir() .. "/" .. port .. ".lock"

  if vim.fn.filereadable(lock_path) == 0 then
    return false, "Lock file does not exist: " .. lock_path
  end

  local ok, err = pcall(function()
    return os.remove(lock_path)
  end)

  if not ok then
    return false, "Failed to remove lock file: " .. (err or "unknown error")
  end

  return true
end

---Update the lock file for the given port
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string result_or_error The lock file path if successful, or error message if failed
---@return string? auth_token The authentication token if successful
function M.update(port)
  if not port or type(port) ~= "number" then
    return false, "Invalid port number"
  end

  local exists = vim.fn.filereadable(get_lock_dir() .. "/" .. port .. ".lock") == 1
  if exists then
    local remove_ok, remove_err = M.remove(port)
    if not remove_ok then
      return false, "Failed to update lock file: " .. remove_err
    end
  end

  return M.create(port)
end

---Write the lock file to every configured profile lock directory.
---Called at server start so Claude CLI sessions under any profile can discover Neovim.
---@param port number
---@param auth_token string Pre-generated auth token
---@return boolean success true if at least one lockfile was written
function M.sync_all(port, auth_token)
  local dirs = M.get_all_lock_dirs()
  local any_ok = false
  for _, dir in ipairs(dirs) do
    pcall(function()
      vim.fn.mkdir(dir, "p")
    end)
    local lock_path = dir .. "/" .. port .. ".lock"
    local workspace_folders = M.get_workspace_folders()
    local lock_content = {
      pid = vim.fn.getpid(),
      workspaceFolders = workspace_folders,
      ideName = "Neovim",
      transport = "ws",
      authToken = auth_token,
    }
    local ok_json, json = pcall(vim.json.encode, lock_content)
    if ok_json and json then
      local f = io.open(lock_path, "w")
      if f then
        f:write(json)
        f:close()
        any_ok = true
      end
    end
  end
  return any_ok
end

---Remove the lock file from every configured profile lock directory.
---Called at server stop to clean up all locations written by sync_all.
---@param port number
function M.remove_all(port)
  for _, dir in ipairs(M.get_all_lock_dirs()) do
    local lock_path = dir .. "/" .. port .. ".lock"
    if vim.fn.filereadable(lock_path) == 1 then
      pcall(os.remove, lock_path)
    end
  end
end

---Read the authentication token from a lock file
---@param port number The port number of the WebSocket server
---@return boolean success Whether the operation was successful
---@return string? auth_token The authentication token if successful, or nil if failed
---@return string? error Error message if operation failed
function M.get_auth_token(port)
  if not port or type(port) ~= "number" then
    return false, nil, "Invalid port number"
  end

  local lock_path = get_lock_dir() .. "/" .. port .. ".lock"

  if vim.fn.filereadable(lock_path) == 0 then
    return false, nil, "Lock file does not exist: " .. lock_path
  end

  local file = io.open(lock_path, "r")
  if not file then
    return false, nil, "Failed to open lock file: " .. lock_path
  end

  local content = file:read("*all")
  file:close()

  if not content or content == "" then
    return false, nil, "Lock file is empty: " .. lock_path
  end

  local ok, lock_data = pcall(vim.json.decode, content)
  if not ok or type(lock_data) ~= "table" then
    return false, nil, "Failed to parse lock file JSON: " .. lock_path
  end

  local auth_token = lock_data.authToken
  if not auth_token or type(auth_token) ~= "string" then
    return false, nil, "No valid auth token found in lock file"
  end

  return true, auth_token, nil
end

---Get active LSP clients using available API
---@return table Array of LSP clients
local function get_lsp_clients()
  if vim.lsp then
    if vim.lsp.get_clients then
      -- Neovim >= 0.11
      return vim.lsp.get_clients()
    elseif vim.lsp.get_active_clients then
      -- Neovim 0.8-0.10
      return vim.lsp.get_active_clients()
    end
  end
  return {}
end

---Get workspace folders for the lock file
---@return table Array of workspace folder paths
function M.get_workspace_folders()
  local folders = {}

  -- Add current working directory
  table.insert(folders, vim.fn.getcwd())

  -- Get LSP workspace folders if available
  local clients = get_lsp_clients()
  for _, client in pairs(clients) do
    if client.config and client.config.workspace_folders then
      for _, ws in ipairs(client.config.workspace_folders) do
        -- Convert URI to path
        local path = ws.uri
        if path:sub(1, 7) == "file://" then
          path = path:sub(8)
        end

        -- Check if already in the list
        local exists = false
        for _, folder in ipairs(folders) do
          if folder == path then
            exists = true
            break
          end
        end

        if not exists then
          table.insert(folders, path)
        end
      end
    end
  end

  return folders
end

return M
