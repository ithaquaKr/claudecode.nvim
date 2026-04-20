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
  if not iso or type(iso) ~= "string" then return nil end
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

---Enumerate all Claude Code credential entries in macOS Keychain.
---Service names match the pattern "Claude Code-credentials[-HASH]" (Claude Code
---appends a per-installation hash suffix, e.g. "Claude Code-credentials-a25e21bb").
---Parses `security dump-keychain` (no password prompt needed) and returns
---{acct, svce} pairs so each entry can be fetched with its exact service name.
---@return table[] entries List of {acct=string|nil, svce=string} tables
local function enumerate_darwin_keychain_entries()
  local raw = vim.fn.system("security dump-keychain 2>/dev/null")
  if vim.v.shell_error ~= 0 or not raw or raw == "" then
    return {}
  end

  local entries = {}
  local seen = {}
  local in_target = false
  local block_acct = nil
  local block_svce = nil

  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^keychain:") or line == "" then
      if in_target and block_svce then
        local key = block_svce .. "\0" .. (block_acct or "")
        if not seen[key] then
          seen[key] = true
          table.insert(entries, { acct = block_acct, svce = block_svce })
        end
      end
      in_target = false
      block_acct = nil
      block_svce = nil
    end
    -- Match both the named "svce" form and the raw 0x00000007 hex-key form.
    -- Accept any service name that starts with "Claude Code-credentials".
    local svce = line:match('"svce"<blob>="(Claude Code%-credentials[^"]*)"')
              or line:match('0x00000007 <blob>="(Claude Code%-credentials[^"]*)"')
    if svce then
      in_target = true
      block_svce = svce
    end
    local acct = line:match('"acct"<blob>="([^"]*)"')
    if acct then block_acct = acct end
  end
  -- Flush the final block.
  if in_target and block_svce then
    local key = block_svce .. "\0" .. (block_acct or "")
    if not seen[key] then
      table.insert(entries, { acct = block_acct, svce = block_svce })
    end
  end

  return entries
end

---Read raw JSON credentials from macOS Keychain using the exact service name
---discovered via enumerate_darwin_keychain_entries().
---@param entry table {acct=string|nil, svce=string}
---@return string|nil raw, string|nil err
local function read_darwin_creds_for_entry(entry)
  local safe_svce = entry.svce:gsub("'", "'\\''")
  local cmd
  if entry.acct then
    local safe_acct = entry.acct:gsub("'", "'\\''")
    cmd = "security find-generic-password -s '" .. safe_svce .. "' -a '" .. safe_acct .. "' -w 2>/dev/null"
  else
    cmd = "security find-generic-password -s '" .. safe_svce .. "' -w 2>/dev/null"
  end
  local raw = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 or not raw or raw:match("^%s*$") then
    return nil, "Keychain: no credentials for " .. entry.svce
  end
  return raw:gsub("[\n\r]+$", ""), nil
end

---Read and return the raw JSON string for credentials.
---On all platforms, checks config_dir/.credentials.json first when config_dir is provided.
---Falls back to macOS Keychain (first entry) or the default credentials file path.
---@param config_dir string|nil Override credentials directory
---@return string|nil raw, string|nil err
local function read_raw_creds(config_dir)
  -- Always try the profile-specific credentials file first when a config dir is given.
  -- This covers macOS users with multiple accounts authenticated to different config dirs
  -- via `CLAUDE_CONFIG_DIR=~/.claude-work claude auth login`.
  if config_dir then
    local path = config_dir .. "/.credentials.json"
    local f = io.open(path, "r")
    if f then
      local raw = f:read("*a")
      f:close()
      if raw and raw ~= "" then
        return raw, nil
      end
    end
  end

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
---@param config_dir string|nil Override credentials directory (Linux/Windows only)
---@return string|nil token, string|nil err
function M.read_token(config_dir)
  local raw, err = read_raw_creds(config_dir)
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

---Extract and validate an OAuth access token from a raw credentials JSON string.
---@param raw string Raw JSON credentials string
---@return string|nil token, string|nil err
local function token_from_raw(raw)
  local ok, creds = pcall(vim.json.decode, raw)
  if not ok or type(creds) ~= "table" then
    return nil, "Failed to parse credentials JSON"
  end
  local oauth = creds.claudeAiOauth
  if not oauth or not oauth.accessToken then
    return nil, "No OAuth token found in credentials"
  end
  local exp = oauth.expiresAt
  if exp and (exp / 1000 - os.time()) < 300 then
    return nil, "OAuth token expired — re-authenticate in Claude Code"
  end
  return oauth.accessToken, nil
end

---Fetch usage + profile for all configured profiles in parallel.
---With no profiles configured, behaves identically to a single-profile fetch.
---On macOS, profiles without a local .credentials.json trigger full Keychain enumeration.
---Each Keychain token is resolved to a profile by calling the profile API and matching
---the returned account email against the account_email field in each profile config.
---callback receives an array of { name, result, err, is_api_key, config } tables.
---@param callback fun(results: table[])
function M.fetch_all_profiles(callback)
  local profiles_ok, profiles_module = pcall(require, "claudecode.profiles")

  if not profiles_ok or not profiles_module.has_profiles() then
    local token, token_err = M.read_token()
    if not token then
      callback({ { name = nil, result = {}, err = token_err } })
      return
    end
    M.fetch(token, function(result, err)
      callback({ { name = nil, result = result, err = err } })
    end)
    return
  end

  local all_profiles = profiles_module.get_all_profiles()
  if #all_profiles == 0 then
    callback({})
    return
  end

  local results = {}
  local pending = 0

  local function finish()
    pending = pending - 1
    if pending == 0 then
      table.sort(results, function(a, b)
        return (a.name or "") < (b.name or "")
      end)
      callback(results)
    end
  end

  -- resolved: profiles whose token is already in hand (file-based creds)
  local resolved = {}

  local function fire_resolved()
    if #resolved == 0 then
      table.sort(results, function(a, b) return (a.name or "") < (b.name or "") end)
      callback(results)
      return
    end
    pending = #resolved
    for _, r in ipairs(resolved) do
      local name = r.name
      local token = r.token
      M.fetch(token, function(result, err)
        table.insert(results, { name = name, result = result, err = err })
        finish()
      end)
    end
  end

  -- keychain_profiles: profile names that need macOS Keychain (no .credentials.json)
  local keychain_profiles = {}
  local pending_classification = #all_profiles

  local function after_classification()
    pending_classification = pending_classification - 1
    if pending_classification > 0 then return end

    if #keychain_profiles > 0 and platform() == "darwin" then
      local keychain_entries = enumerate_darwin_keychain_entries()

      -- Read all valid tokens from Keychain synchronously (dump-keychain needs no password)
      local kc_tokens = {}
      for _, entry in ipairs(keychain_entries) do
        local raw, _ = read_darwin_creds_for_entry(entry)
        if raw then
          local t, _ = token_from_raw(raw)
          if t then table.insert(kc_tokens, t) end
        end
      end

      if #kc_tokens == 0 then
        for _, name in ipairs(keychain_profiles) do
          table.insert(results, {
            name = name, result = {},
            err = "Keychain: no credentials found — re-authenticate in Claude Code",
          })
        end
        fire_resolved()
        return
      end

      -- Build email→profile-name map for profiles that have account_email configured.
      -- Profiles without account_email are "bare" and get paired with leftover tokens.
      local email_to_profile = {}
      local bare_kc_profiles = {}
      for _, name in ipairs(keychain_profiles) do
        local email = profiles_module.get_account_email and profiles_module.get_account_email(name)
        if email then
          email_to_profile[email] = name
        else
          table.insert(bare_kc_profiles, name)
        end
      end

      -- Async: call M.fetch for every Keychain token in parallel.
      -- The profile API response includes account.email, which we use to match tokens
      -- to profiles. This is the only reliable way since the tokens are opaque.
      local kc_pending = #kc_tokens
      local kc_fetched = {}

      local function after_kc_done()
        local claimed = {}
        local unmatched_kc = {}

        for _, kr in ipairs(kc_fetched) do
          local api_email = type(kr.result) == "table"
            and type(kr.result.profile) == "table"
            and type(kr.result.profile.account) == "table"
            and kr.result.profile.account.email
          local pname = (type(api_email) == "string") and email_to_profile[api_email]
          if pname and not claimed[pname] then
            claimed[pname] = true
            table.insert(results, { name = pname, result = kr.result, err = kr.err })
          else
            table.insert(unmatched_kc, kr)
          end
        end

        -- Error entries for email-pinned profiles that had no API match
        for email, pname in pairs(email_to_profile) do
          if not claimed[pname] then
            table.insert(results, {
              name = pname, result = {},
              err = "No Keychain account matching " .. email .. " — verify account_email in profile config",
            })
          end
        end

        -- Pair bare profiles with remaining unmatched Keychain tokens (order not guaranteed)
        for i, name in ipairs(bare_kc_profiles) do
          if unmatched_kc[i] then
            local kr = unmatched_kc[i]
            table.insert(results, { name = name, result = kr.result, err = kr.err })
          else
            table.insert(results, {
              name = name, result = {},
              err = "Keychain: no credentials for this profile",
            })
          end
        end

        fire_resolved()
      end

      for _, token in ipairs(kc_tokens) do
        M.fetch(token, function(result, err)
          table.insert(kc_fetched, { token = token, result = result, err = err })
          kc_pending = kc_pending - 1
          if kc_pending == 0 then
            after_kc_done()
          end
        end)
      end
      -- after_kc_done → fire_resolved; don't fall through
      return
    elseif #keychain_profiles > 0 then
      -- Non-macOS: use the default credentials file for each profile
      for _, name in ipairs(keychain_profiles) do
        local config_dir = profiles_module.get_config_dir(name)
        local token, token_err = M.read_token(config_dir)
        if token then
          table.insert(resolved, { name = name, token = token })
        else
          table.insert(results, { name = name, result = {}, err = token_err })
        end
      end
    end

    fire_resolved()
  end

  for _, p in ipairs(all_profiles) do
    local profile_name = p.name
    local cfg = p.config

    if cfg.env and cfg.env.ANTHROPIC_API_KEY then
      table.insert(results, { name = profile_name, result = {}, err = nil, is_api_key = true, config = cfg })
      after_classification()
    else
      -- Try file-based credentials first (works on all platforms; on macOS only when
      -- the user authenticated with CLAUDE_CONFIG_DIR set, writing a .credentials.json)
      local config_dir = profiles_module.get_config_dir(profile_name)
      local file_raw = nil
      if config_dir then
        local expanded = vim.fn.expand(config_dir)
        local path = expanded .. "/.credentials.json"
        local f = io.open(path, "r")
        if f then
          local raw = f:read("*a")
          f:close()
          if raw and raw ~= "" then file_raw = raw end
        end
      end

      if file_raw then
        local token, token_err = token_from_raw(file_raw)
        if token then
          table.insert(resolved, { name = profile_name, token = token })
        else
          table.insert(results, { name = profile_name, result = {}, err = token_err })
        end
        after_classification()
      elseif platform() == "darwin" then
        -- Will be handled in bulk via Keychain enumeration after all profiles are classified
        table.insert(keychain_profiles, profile_name)
        after_classification()
      else
        local token, token_err = M.read_token(config_dir)
        if token then
          table.insert(resolved, { name = profile_name, token = token })
        else
          table.insert(results, { name = profile_name, result = {}, err = token_err })
        end
        after_classification()
      end
    end
  end
end

---Render account + usage lines for all profiles.
---With a single unnamed result (no profiles configured) delegates to render_lines.
---With multiple results renders one named section per profile.
---@param profile_results table[] Array from fetch_all_profiles callback
---@param W number popup content width
---@return string[] lines
function M.render_all_profiles_lines(profile_results, W)
  W = W or 54

  if #profile_results == 0 then
    return { "  " .. string.rep("─", W - 4), "  Account   no profiles configured" }
  end

  if #profile_results == 1 and profile_results[1].name == nil then
    local pr = profile_results[1]
    return M.render_lines(pr.result or {}, pr.err, W)
  end

  local SEP = "  " .. string.rep("─", W - 4)
  local all_lines = { SEP, "  Profiles" }

  -- Mark the default profile with ● so it's easy to spot
  local default_name
  local prof_ok, prof_mod = pcall(require, "claudecode.profiles")
  if prof_ok then default_name = prof_mod.get_active_name() end

  for _, pr in ipairs(profile_results) do
    -- Blank line before each profile entry
    table.insert(all_lines, "")
    local marker = (pr.name ~= nil and pr.name == default_name) and " ●" or ""
    table.insert(all_lines, "  " .. (pr.name or "—") .. marker)

    if pr.is_api_key then
      local key = (pr.config and pr.config.env and pr.config.env.ANTHROPIC_API_KEY) or ""
      local masked = key ~= "" and (key:sub(1, 10) .. "…") or "(key hidden)"
      table.insert(all_lines, "  Account   API key  " .. masked)
    else
      -- render_lines returns: [SEP, Account line, Plan line, "", usage rows...]
      -- Skip [1] (SEP — replaced by the profile name header above) and blank lines.
      local section = M.render_lines(pr.result or {}, pr.err, W)
      for i, l in ipairs(section) do
        if i > 1 and l ~= "" then
          table.insert(all_lines, l)
        end
      end
    end
  end

  return all_lines
end

return M
