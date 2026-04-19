---Profile management for claudecode.nvim.
---Handles multiple subscription accounts and API-key configurations,
---each pointing to an independent CLAUDE_CONFIG_DIR.
---@module 'claudecode.profiles'

local M = {}

---@type table<string, table>|nil
local _profiles = nil

---@type string|nil
local _active = nil

---Configure the module. Called from init.lua setup().
---@param profiles table<string, table>|nil
---@param active_profile string|nil
function M.setup(profiles, active_profile)
  _profiles = profiles
  _active = active_profile
end

---@return boolean
function M.has_profiles()
  return _profiles ~= nil and next(_profiles) ~= nil
end

---Resolve the CLAUDE_CONFIG_DIR for a profile (or the active profile).
---@param profile_name string|nil nil = active profile
---@return string|nil config_dir Expanded absolute path, or nil if not set
function M.get_config_dir(profile_name)
  local name = profile_name or _active
  if not name or not _profiles or not _profiles[name] then
    return nil
  end
  local p = _profiles[name]
  if p.claude_config_dir then
    return vim.fn.expand(p.claude_config_dir)
  end
  return nil
end

---Resolve the projects directory for a profile.
---@param profile_name string|nil nil = active profile
---@return string projects_dir Always returns a valid path
function M.get_projects_dir(profile_name)
  local config_dir = M.get_config_dir(profile_name)
  if config_dir then
    return config_dir .. "/projects/"
  end
  local env_dir = os.getenv("CLAUDE_CONFIG_DIR")
  if env_dir and env_dir ~= "" then
    return vim.fn.expand(env_dir) .. "/projects/"
  end
  return vim.fn.expand("~/.claude/projects/")
end

---Resolve the IDE lock-files directory for a profile.
---@param profile_name string|nil nil = active profile
---@return string lock_dir
function M.get_lock_dir(profile_name)
  local config_dir = M.get_config_dir(profile_name)
  if config_dir then
    return config_dir .. "/ide"
  end
  local env_dir = os.getenv("CLAUDE_CONFIG_DIR")
  if env_dir and env_dir ~= "" then
    return vim.fn.expand(env_dir .. "/ide")
  end
  return vim.fn.expand("~/.claude/ide")
end

---Return the account_email configured for a profile, if any.
---Used on macOS to fetch the exact Keychain entry for this profile.
---@param profile_name string|nil nil = active profile
---@return string|nil email
function M.get_account_email(profile_name)
  local name = profile_name or _active
  if not name or not _profiles or not _profiles[name] then
    return nil
  end
  return _profiles[name].account_email
end

---Build the env-var table to inject when launching Claude CLI for a profile.
---Includes CLAUDE_CONFIG_DIR (when the profile sets one) and profile.env overrides.
---@param profile_name string|nil nil = active profile
---@return table<string, string>
function M.get_profile_env(profile_name)
  local name = profile_name or _active
  local env = {}
  if not name or not _profiles or not _profiles[name] then
    return env
  end
  local p = _profiles[name]
  local config_dir = M.get_config_dir(name)
  if config_dir then
    env.CLAUDE_CONFIG_DIR = config_dir
  end
  if p.env then
    for k, v in pairs(p.env) do
      env[k] = v
    end
  end
  return env
end

---Return all configured profiles as an array sorted by name.
---@return {name: string, config: table}[]
function M.get_all_profiles()
  if not _profiles then
    return {}
  end
  local result = {}
  for name, cfg in pairs(_profiles) do
    table.insert(result, { name = name, config = cfg })
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

---@return string|nil
function M.get_active_name()
  return _active
end

---Switch the active profile. Pass nil to revert to default ~/.claude.
---@param name string|nil
function M.set_active(name)
  if name ~= nil and (not _profiles or not _profiles[name]) then
    error("claudecode.profiles: unknown profile '" .. tostring(name) .. "'")
  end
  _active = name
end

return M
