---Account-level usage fetching for claudecode.nvim.
---Reads OAuth credentials from macOS Keychain or ~/.claude/.credentials.json
---(Linux/Windows), then calls the Anthropic oauth usage and profile endpoints.
---@module 'claudecode.usage'

local M = {}

-- Compute local-timezone offset once at load time (seconds east of UTC).
-- os.time(tbl) treats tbl as LOCAL time, so:
--   os.time(os.date("!*t", t)) == t - tz_offset
-- Therefore tz_offset = t - os.time(os.date("!*t", t)).
local _TZ_OFF = (function()
  local t = os.time()
  return t - os.time(os.date("!*t", t))
end)()

---Parse an ISO 8601 UTC timestamp string to a Unix epoch (seconds).
---@param iso string e.g. "2026-04-17T17:30:00Z"
---@return number|nil
local function iso_utc_to_epoch(iso)
  if not iso then return nil end
  local y, mo, d, h, mi, s = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  return os.time({
    year = tonumber(y), month = tonumber(mo), day = tonumber(d),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
    isdst = false,
  }) + _TZ_OFF
end

---Format a seconds-remaining value as a compact human string.
---@param secs number
---@return string
local function fmt_remaining(secs)
  if not secs or secs <= 0 then return "expired" end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  local m = math.floor((secs % 3600) / 60)
  if d > 0 then return d .. "d " .. h .. "h"
  elseif h > 0 then return h .. "h " .. m .. "m"
  else return m .. "m"
  end
end

---Render a fixed-width ASCII progress bar.
---@param pct number 0-100
---@param width number bar character width
---@return string
local function bar(pct, width)
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  local filled = math.floor(pct * width / 100 + 0.5)
  return string.rep("█", filled) .. string.rep("░", width - filled)
end

---Detect the platform.
---@return "darwin"|"linux"|"windows"
local function platform()
  local uname = vim.loop.os_uname()
  local s = uname.sysname:lower()
  if s:find("darwin") then return "darwin" end
  if s:find("windows") or s:find("mingw") or s:find("cygwin") then return "windows" end
  return "linux"
end

---Locate the credentials JSON file path on Linux / Windows.
---@return string
local function creds_file_path()
  local cfg = os.getenv("CLAUDE_CONFIG_DIR")
  if cfg and cfg ~= "" then
    return cfg .. "/.credentials.json"
  end
  if platform() == "windows" then
    local appdata = os.getenv("APPDATA") or ""
    return appdata .. "\\Claude\\.credentials.json"
  end
  return (os.getenv("HOME") or "") .. "/.claude/.credentials.json"
end

---Read and return the raw JSON string for credentials.
---On macOS uses the Keychain; on Linux/Windows reads the credentials file.
---@return string|nil raw, string|nil err
local function read_raw_creds()
  if platform() == "darwin" then
    local raw = vim.fn.system(
      "security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null"
    )
    if vim.v.shell_error ~= 0 or not raw or raw:match("^%s*$") then
      return nil, "Keychain: credentials not found — re-authenticate in Claude Code"
    end
    return raw:gsub("[\n\r]+$", ""), nil
  else
    local path = creds_file_path()
    local f = io.open(path, "r")
    if not f then
      return nil, "Credentials file not found: " .. path
    end
    local raw = f:read("*a")
    f:close()
    return raw, nil
  end
end

---Read the OAuth access token from the platform credential store.
---@return string|nil token, string|nil err
function M.read_token()
  local raw, err = read_raw_creds()
  if not raw then return nil, err end

  local ok, creds = pcall(vim.json.decode, raw)
  if not ok or type(creds) ~= "table" then
    return nil, "Failed to parse credentials JSON"
  end

  local oauth = creds.claudeAiOauth
  if not oauth or not oauth.accessToken then
    return nil, "No OAuth token found in credentials"
  end

  -- Treat token as expired when < 5 minutes remain (expiresAt is unix milliseconds)
  local exp = oauth.expiresAt
  if exp and (exp / 1000 - os.time()) < 300 then
    return nil, "OAuth token expired — re-authenticate in Claude Code"
  end

  return oauth.accessToken, nil
end

---Async HTTP GET via curl, JSON-decoded result passed to callback.
---@param url string
---@param token string Bearer token
---@param callback fun(data: table|nil, err: string|nil)
local function curl_get(url, token, callback)
  local chunks = {}
  vim.fn.jobstart({
    "curl", "-s", "--max-time", "10",
    "-H", "Authorization: Bearer " .. token,
    "-H", "anthropic-beta: oauth-2025-04-20",
    "-H", "User-Agent: claude-code/2.0.37",
    url,
  }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(chunks, line) end
      end
    end,
    on_exit = function(_, code)
      local body = table.concat(chunks, "")
      if code ~= 0 or body == "" then
        vim.schedule(function() callback(nil, "curl error (exit " .. code .. ")") end)
        return
      end
      local ok, parsed = pcall(vim.json.decode, body)
      if not ok then
        vim.schedule(function() callback(nil, "invalid JSON from API") end)
        return
      end
      vim.schedule(function() callback(parsed, nil) end)
    end,
  })
end

---Fetch usage + profile in parallel.
---callback receives { usage=table|nil, profile=table|nil } and a combined error string.
---@param token string
---@param callback fun(result: table, err: string|nil)
function M.fetch(token, callback)
  local BASE = "https://api.anthropic.com"
  local result = {}
  local pending = 2
  local errors = {}

  local function done(key, data, err)
    if err then table.insert(errors, err) end
    if data then result[key] = data end
    pending = pending - 1
    if pending == 0 then
      callback(result, #errors > 0 and table.concat(errors, "; ") or nil)
    end
  end

  curl_get(BASE .. "/api/oauth/usage", token, function(d, e) done("usage", d, e) end)
  curl_get(BASE .. "/api/oauth/profile", token, function(d, e) done("profile", d, e) end)
end

---Build the account + usage section lines for the status popup.
---@param result table { usage=table|nil, profile=table|nil }
---@param fetch_err string|nil
---@param W number popup content width
---@return string[] lines
function M.render_lines(result, fetch_err, W)
  W = W or 54
  local SEP = "  " .. string.rep("─", W - 4)
  local lines = { SEP }

  -- Profile -----------------------------------------------------------
  local profile = result.profile
  if type(profile) == "table" then
    local account = type(profile.account) == "table" and profile.account or {}
    local org = type(profile.organization) == "table" and profile.organization or {}

    local email = account.email or ""
    local name = account.display_name or ""
    local who = (name ~= "" and name ~= email) and (name .. " <" .. email .. ">") or email
    if vim.fn.strdisplaywidth(who) > W - 14 then
      who = vim.fn.strcharpart(who, 0, W - 17) .. "…"
    end
    table.insert(lines, "  Account   " .. who)

    -- Plan badges
    local badges = {}
    if (org.organization_type or "") == "claude_enterprise" then
      table.insert(badges, "ENTERPRISE")
    end
    if account.has_claude_max then table.insert(badges, "MAX") end
    if account.has_claude_pro then table.insert(badges, "PRO") end

    local tier_map = {
      default_claude_max_5x = "5x",
      default_claude_max_20x = "20x",
    }
    local tier = tier_map[org.rate_limit_tier or ""] or (org.rate_limit_tier or "")
    local plan_str = #badges > 0 and table.concat(badges, " · ") or "—"
    if tier ~= "" then plan_str = plan_str .. "  ·  " .. tier end
    table.insert(lines, "  Plan      " .. plan_str)
  elseif fetch_err then
    table.insert(lines, "  Account   " .. fetch_err)
  end

  -- Usage bars --------------------------------------------------------
  local usage = result.usage
  if type(usage) == "table" then
    table.insert(lines, "")

    local BAR_W = 18

    local function usage_row(label, window)
      if type(window) ~= "table" then return end
      local pct = tonumber(window.utilization) or 0
      local epoch = iso_utc_to_epoch(window.resets_at)
      local reset_str = epoch and ("  → " .. fmt_remaining(epoch - os.time())) or ""
      table.insert(lines, string.format(
        "  %-8s  %s  %3d%%%s",
        label, bar(pct, BAR_W), math.floor(pct + 0.5), reset_str
      ))
    end

    usage_row("5-hour", usage.five_hour)
    usage_row("7-day", usage.seven_day)
    if type(usage.seven_day_sonnet) == "table" then usage_row("7d/sonnet", usage.seven_day_sonnet) end
    if type(usage.seven_day_opus) == "table" then usage_row("7d/opus", usage.seven_day_opus) end
  end

  return lines
end

return M
