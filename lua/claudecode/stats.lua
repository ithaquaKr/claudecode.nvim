---Local usage statistics computed from ~/.claude/projects JSONL files.
---@module 'claudecode.stats'

local M = {}

local function get_projects_dir()
  local cfg = os.getenv("CLAUDE_CONFIG_DIR")
  if cfg and cfg ~= "" then
    return cfg .. "/projects"
  end
  return (os.getenv("HOME") or "") .. "/.claude/projects"
end

-- Compute local timezone offset once (seconds east of UTC).
local _TZ_OFF = (function()
  local t = os.time()
  local utc = os.date("!*t", t)
  ---@diagnostic disable-next-line: param-type-mismatch
  return t - os.time(utc)
end)()

local function parse_ts(ts)
  if not ts or type(ts) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s = ts:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    return nil
  end
  return os.time({
    year = tonumber(y) or 0,
    month = tonumber(mo) or 0,
    day = tonumber(d) or 0,
    hour = tonumber(h) or 0,
    min = tonumber(mi) or 0,
    sec = tonumber(s) or 0,
    isdst = false,
  }) + _TZ_OFF
end

local function short_model(m)
  if not m or m == "" or m == "<synthetic>" then
    return ""
  end
  local s = m:match("claude%-(.+)") or m
  s = s:gsub("%-(%d+)%-(%d+)$", " %1.%2")
  return s:sub(1, 1):upper() .. s:sub(2)
end

---Compute stats from local JSONL session files.
---@param filter "all"|"30d"|"7d"
---@return table stats
function M.compute(filter)
  local dir = get_projects_dir()
  local dh = vim.loop.fs_opendir(dir, nil, 100)
  if not dh then
    return {}
  end

  local cutoff = nil
  if filter == "30d" then
    cutoff = os.time() - 30 * 86400
  elseif filter == "7d" then
    cutoff = os.time() - 7 * 86400
  end

  local sessions = {}
  local session_count = 0
  local messages = 0
  local tokens = 0
  local hour_counts = {}
  local model_tokens = {}
  local model_calls = {}
  local daily_tokens = {}

  while true do
    local entries = vim.loop.fs_readdir(dh)
    if not entries then
      break
    end
    for _, ent in ipairs(entries) do
      if ent.type == "directory" then
        local proj_path = dir .. "/" .. ent.name
        local ph = vim.loop.fs_opendir(proj_path, nil, 200)
        if ph then
          while true do
            local pents = vim.loop.fs_readdir(ph)
            if not pents then
              break
            end
            for _, pent in ipairs(pents) do
              if pent.type == "file" and pent.name:match("%.jsonl$") then
                local fpath = proj_path .. "/" .. pent.name
                local f = io.open(fpath, "r")
                if f then
                  for line in f:lines() do
                    if line ~= "" then
                      local ok, entry = pcall(vim.json.decode, line)
                      if ok and type(entry) == "table" and entry.type == "assistant" then
                        local ts = parse_ts(entry.timestamp)
                        if ts and (not cutoff or ts >= cutoff) then
                          local msg = entry.message
                          if type(msg) == "table" and type(msg.usage) == "table" then
                            local u = msg.usage
                            local total = (u.input_tokens or 0)
                              + (u.cache_read_input_tokens or 0)
                              + (u.cache_creation_input_tokens or 0)
                              + (u.output_tokens or 0)
                            if total > 0 then
                              messages = messages + 1
                              tokens = tokens + total
                              local sid = entry.sessionId or "?"
                              if not sessions[sid] then
                                sessions[sid] = true
                                session_count = session_count + 1
                              end
                              local hh = tonumber(os.date("%H", ts)) or 0
                              hour_counts[hh] = (hour_counts[hh] or 0) + 1
                              local model = (type(msg.model) == "string") and msg.model or ""
                              if model ~= "" and model ~= "<synthetic>" then
                                model_tokens[model] = (model_tokens[model] or 0) + total
                                model_calls[model] = (model_calls[model] or 0) + 1
                              end
                              local day = os.date("%Y-%m-%d", ts)
                              daily_tokens[day] = (daily_tokens[day] or 0) + total
                            end
                          end
                        end
                      end
                    end
                  end
                  f:close()
                end
              end
            end
          end
          vim.loop.fs_closedir(ph)
        end
      end
    end
  end
  vim.loop.fs_closedir(dh)

  -- Sorted day list
  local days_list = {}
  for day in pairs(daily_tokens) do
    table.insert(days_list, day)
  end
  table.sort(days_list)
  local active_days = #days_list

  -- Day set for streak computation
  local days_set = {}
  for _, d in ipairs(days_list) do
    days_set[d] = true
  end

  -- Current streak (walk backwards from today)
  local current_streak = 0
  local check = os.time()
  if not days_set[os.date("%Y-%m-%d", check)] then
    check = check - 86400
  end
  while days_set[os.date("%Y-%m-%d", check)] do
    current_streak = current_streak + 1
    check = check - 86400
  end

  -- Longest streak
  local longest = 0
  local cur_run = 0
  local prev_day = nil
  for _, day in ipairs(days_list) do
    if prev_day then
      local pt = parse_ts(prev_day .. "T12:00:00")
      local ct = parse_ts(day .. "T12:00:00")
      if pt and ct and math.floor((ct - pt) / 86400 + 0.5) == 1 then
        cur_run = cur_run + 1
      else
        if cur_run > longest then
          longest = cur_run
        end
        cur_run = 1
      end
    else
      cur_run = 1
    end
    prev_day = day
  end
  if cur_run > longest then
    longest = cur_run
  end

  -- Peak hour
  local peak_hour = 0
  local peak_count = 0
  for hh, c in pairs(hour_counts) do
    if c > peak_count then
      peak_count = c
      peak_hour = hh
    end
  end

  -- Favorite model (most tokens)
  local fav_model = ""
  local fav_tokens = 0
  for model, t in pairs(model_tokens) do
    if t > fav_tokens then
      fav_tokens = t
      fav_model = model
    end
  end

  -- Sorted models list
  local models = {}
  for model, t in pairs(model_tokens) do
    table.insert(models, { name = model, tokens = t, calls = model_calls[model] or 0 })
  end
  table.sort(models, function(a, b)
    return a.tokens > b.tokens
  end)

  return {
    sessions = session_count,
    messages = messages,
    tokens = tokens,
    active_days = active_days,
    current_streak = current_streak,
    longest_streak = longest,
    peak_hour = peak_hour,
    favorite_model = short_model(fav_model),
    daily_tokens = daily_tokens,
    days_list = days_list,
    models = models,
  }
end

return M