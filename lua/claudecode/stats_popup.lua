---Stats popup for claudecode.nvim.
---Renders a floating window with usage statistics computed from local session files.
---@module 'claudecode.stats_popup'

local M = {}

local W = 70 -- content width (border adds 2 on each side)

-- ── helpers ────────────────────────────────────────────────────────────────

local function fmt_num(n)
  if n >= 1e9 then
    return string.format("%.1fB", n / 1e9)
  elseif n >= 1e6 then
    return string.format("%.1fM", n / 1e6)
  elseif n >= 1e3 then
    return string.format("%.1fK", n / 1e3)
  else
    return tostring(math.floor(n))
  end
end

local function fmt_hour(h)
  if h == 0 then
    return "12 AM"
  elseif h < 12 then
    return h .. " AM"
  elseif h == 12 then
    return "12 PM"
  else
    return (h - 12) .. " PM"
  end
end

local function short_model_name(m)
  if not m or m == "" then
    return "—"
  end
  local s = m:match("claude%-(.+)") or m
  s = s:gsub("%-(%d+)%-(%d+)$", " %1.%2")
  return s:sub(1, 1):upper() .. s:sub(2)
end

local BOOKS = {
  { name = "a tweet", tokens = 50 },
  { name = "a news article", tokens = 800 },
  { name = "Animal Farm", tokens = 29000 },
  { name = "The Great Gatsby", tokens = 110000 },
  { name = "1984", tokens = 130000 },
  { name = "The Hobbit", tokens = 220000 },
  { name = "Harry Potter 1", tokens = 500000 },
  { name = "The Lord of the Rings", tokens = 650000 },
  { name = "War and Peace", tokens = 1800000 },
  { name = "The Complete Works of Shakespeare", tokens = 4000000 },
}

local function fun_comparison(total_tokens)
  if total_tokens <= 0 then
    return ""
  end
  local best_name = ""
  local best_mult = 0
  for _, b in ipairs(BOOKS) do
    local mult = math.floor(total_tokens / b.tokens)
    if mult >= 2 then
      best_name = b.name
      best_mult = mult
    end
  end
  if best_mult < 2 then
    return ""
  end
  return string.format("You've used ~%s× more tokens than %s.", fmt_num(best_mult), best_name)
end

local function bar(pct, width)
  pct = math.max(0, math.min(100, tonumber(pct) or 0))
  local filled = math.floor(pct * width / 100 + 0.5)
  return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function sdw(s)
  return vim.fn.strdisplaywidth(s)
end

local function rpad(s, width)
  local w = sdw(s)
  if w < width then
    return s .. string.rep(" ", width - w)
  end
  return s
end

-- ── heatmap ────────────────────────────────────────────────────────────────

local HEATMAP_HLS = {
  "ClaudeStatsHeatmap0",
  "ClaudeStatsHeatmap1",
  "ClaudeStatsHeatmap2",
  "ClaudeStatsHeatmap3",
}
-- Unicode squares for levels 0-3
local HEATMAP_CH = { "░", "▒", "▓", "█" }

local function build_heatmap(daily_tokens, weeks, group_size)
  weeks = weeks or 15
  group_size = group_size or 5

  local max_day = 0
  for _, t in pairs(daily_tokens) do
    if t > max_day then
      max_day = t
    end
  end

  -- Start grid on the Monday of the week containing (weeks-1) weeks ago
  local today = os.time()
  local today_dow = tonumber(os.date("%w", today)) or 0 -- 0=Sun
  local mon_offset = (today_dow == 0) and 6 or (today_dow - 1)
  local cur_week_mon = today - mon_offset * 86400
  local grid_start = cur_week_mon - (weeks - 1) * 7 * 86400

  -- grid[row][col]: row=0 (Mon) .. 6 (Sun), col=0..weeks-1
  local grid = {}
  for row = 0, 6 do
    grid[row] = {}
    for col = 0, weeks - 1 do
      local day_t = grid_start + col * 7 * 86400 + row * 86400
      local day_str = os.date("%Y-%m-%d", day_t)
      local toks = daily_tokens[day_str] or 0
      local future = day_t > today + 86400
      local level
      if future or toks == 0 then
        level = 0
      elseif max_day > 0 then
        local ratio = toks / max_day
        if ratio < 0.15 then
          level = 1
        elseif ratio < 0.5 then
          level = 2
        else
          level = 3
        end
      else
        level = 0
      end
      grid[row][col] = { level = level }
    end
  end
  return grid, weeks, group_size
end

-- Returns {lines, hls} where hls are {lnum, col, len, hl} with lnum relative to first line.
local function render_heatmap(daily_tokens, weeks, group_size)
  local grid, num_weeks, grp = build_heatmap(daily_tokens, weeks, group_size)
  local DAY_LABELS = { "M", "T", "W", "T", "F", "S", "S" }
  local GAP = "  "
  local INDENT = "  "

  local lines = {}
  local hls = {}

  for row = 0, 6 do
    local parts = {}
    local byte_off = #INDENT + 2 -- "  X " prefix
    local row_hls = {}

    for col = 0, num_weeks - 1 do
      if col > 0 and col % grp == 0 then
        table.insert(parts, GAP)
        byte_off = byte_off + #GAP
      end
      local cell = grid[row][col]
      local ch = HEATMAP_CH[cell.level + 1]
      local cell_chars = ch .. ch
      table.insert(row_hls, { col = byte_off, len = #cell_chars, hl = HEATMAP_HLS[cell.level + 1] })
      table.insert(parts, cell_chars .. " ")
      byte_off = byte_off + #cell_chars + 1
    end

    local lnum = #lines
    table.insert(lines, INDENT .. DAY_LABELS[row + 1] .. " " .. table.concat(parts))
    for _, h in ipairs(row_hls) do
      table.insert(hls, { lnum = lnum, col = h.col, len = h.len, hl = h.hl })
    end
  end

  return lines, hls
end

-- ── highlight setup ────────────────────────────────────────────────────────

local function setup_highlights()
  if vim.fn.hlexists("ClaudeStatsHeatmap0") == 1 then
    return
  end
  local dark = vim.o.background == "dark"
  if dark then
    vim.api.nvim_set_hl(0, "ClaudeStatsHeatmap0", { fg = "#2d3748" })
    vim.api.nvim_set_hl(0, "ClaudeStatsHeatmap1", { fg = "#2b5797" })
    vim.api.nvim_set_hl(0, "ClaudeStatsHeatmap2", { fg = "#4a90d9" })
    vim.api.nvim_set_hl(0, "ClaudeStatsHeatmap3", { fg = "#74b9ff" })
  else
    vim.api.nvim_set_hl(0, "ClaudeStatsHeatmap0", { fg = "#e2e8f0" })
    vim.api.nvim_set_hl(0, "ClaudeStatsHeatmap1", { fg = "#90cdf4" })
    vim.api.nvim_set_hl(0, "ClaudeStatsHeatmap2", { fg = "#3182ce" })
    vim.api.nvim_set_hl(0, "ClaudeStatsHeatmap3", { fg = "#1a365d" })
  end
  vim.api.nvim_set_hl(0, "ClaudeStatsTab", { bold = true })
  vim.api.nvim_set_hl(0, "ClaudeStatsTabSel", { bold = true, underline = true })
  vim.api.nvim_set_hl(0, "ClaudeStatsFilter", {})
  vim.api.nvim_set_hl(0, "ClaudeStatsFilterSel", { bold = true, reverse = true })
  vim.api.nvim_set_hl(0, "ClaudeStatsLabel", { link = "Comment" })
  vim.api.nvim_set_hl(0, "ClaudeStatsValue", { bold = true })
  vim.api.nvim_set_hl(0, "ClaudeStatsBar", { fg = "#4a90d9" })
  vim.api.nvim_set_hl(0, "ClaudeStatsFun", { italic = true, link = "Comment" })
end

-- ── line builder ───────────────────────────────────────────────────────────

-- tab: "overview"|"models",  filter: "all"|"30d"|"7d"
-- stats: table from stats.compute() or nil (loading)
local function build_lines(tab, filter, stats)
  local lines = {}
  local hls = {} -- {lnum=0-based, col=byte, len=bytes, hl=group}

  local function push(s)
    table.insert(lines, s)
  end

  -- ── header: tabs + time filter ────────────────────────────────────────
  push("")
  local tabs_defs = { { label = "Overview", key = "overview" }, { label = "Models", key = "models" } }
  local filter_defs = { { label = "All", key = "all" }, { label = "30d", key = "30d" }, { label = "7d", key = "7d" } }

  -- Build left portion
  local left = "  "
  local tab_positions = {}
  for _, t in ipairs(tabs_defs) do
    table.insert(tab_positions, { col = #left, label = t.label, key = t.key })
    left = left .. t.label .. "    "
  end

  -- Build right portion
  local right = ""
  local filter_positions = {}
  for _, f in ipairs(filter_defs) do
    table.insert(filter_positions, { col = #right, label = f.label, key = f.key })
    right = right .. f.label .. "  "
  end
  right = right:sub(1, -3) -- trim trailing spaces

  local gap = W - sdw(left) - sdw(right)
  if gap < 1 then
    gap = 1
  end
  local header = left .. string.rep(" ", gap) .. right
  local right_base = #left + gap -- byte offset where right section begins

  local hdr_lnum = #lines
  push(header)

  for _, t in ipairs(tab_positions) do
    local grp = (t.key == tab) and "ClaudeStatsTabSel" or "ClaudeStatsTab"
    table.insert(hls, { lnum = hdr_lnum, col = t.col, len = #t.label, hl = grp })
  end
  for _, f in ipairs(filter_positions) do
    local grp = (f.key == filter) and "ClaudeStatsFilterSel" or "ClaudeStatsFilter"
    table.insert(hls, { lnum = hdr_lnum, col = right_base + f.col, len = #f.label, hl = grp })
  end

  push("")

  if not stats then
    push("  Loading…")
    push("")
    return lines, hls
  end

  if tab == "overview" then
    -- ── stats grid ──────────────────────────────────────────────────────
    local COL = math.floor(W / 4)
    local grid_items = {
      { label = "Sessions", value = fmt_num(stats.sessions or 0) },
      { label = "Messages", value = fmt_num(stats.messages or 0) },
      { label = "Total tokens", value = fmt_num(stats.tokens or 0) },
      { label = "Active days", value = tostring(stats.active_days or 0) },
      { label = "Current streak", value = (stats.current_streak or 0) .. "d" },
      { label = "Longest streak", value = (stats.longest_streak or 0) .. "d" },
      { label = "Peak hour", value = fmt_hour(stats.peak_hour or 0) },
      { label = "Favorite model", value = short_model_name(stats.favorite_model) },
    }

    for row = 0, 1 do
      local label_line = ""
      local value_line = ""
      local lhl = {}
      local vhl = {}
      for ci = 0, 3 do
        local item = grid_items[row * 4 + ci + 1]
        if item then
          local lbl_str = "  " .. item.label
          local val_str = "  " .. item.value
          local lbl_col = #label_line
          local val_col = #value_line
          table.insert(lhl, { col = lbl_col, len = #lbl_str, hl = "ClaudeStatsLabel" })
          table.insert(vhl, { col = val_col, len = #val_str, hl = "ClaudeStatsValue" })
          label_line = label_line .. rpad(lbl_str, COL)
          value_line = value_line .. rpad(val_str, COL)
        end
      end
      local ll = #lines
      push(label_line)
      push(value_line)
      push("")
      for _, h in ipairs(lhl) do
        table.insert(hls, { lnum = ll, col = h.col, len = h.len, hl = h.hl })
      end
      for _, h in ipairs(vhl) do
        table.insert(hls, { lnum = ll + 1, col = h.col, len = h.len, hl = h.hl })
      end
    end

    -- ── heatmap ─────────────────────────────────────────────────────────
    local hmap_weeks = 15
    local hmap_group = 5
    if filter == "30d" then
      hmap_weeks = 5
      hmap_group = 5
    elseif filter == "7d" then
      hmap_weeks = 2
      hmap_group = 2
    end

    local hmap_lines, hmap_hls = render_heatmap(stats.daily_tokens or {}, hmap_weeks, hmap_group)
    local hmap_offset = #lines
    for _, h in ipairs(hmap_hls) do
      table.insert(hls, { lnum = hmap_offset + h.lnum, col = h.col, len = h.len, hl = h.hl })
    end
    for _, l in ipairs(hmap_lines) do
      push(l)
    end
    push("")

    -- ── fun comparison ──────────────────────────────────────────────────
    local fun = fun_comparison(stats.tokens or 0)
    if fun ~= "" then
      local fun_lnum = #lines
      push("  " .. fun)
      table.insert(hls, { lnum = fun_lnum, col = 2, len = #fun, hl = "ClaudeStatsFun" })
    end
    push("")
  else
    -- ── Models tab ──────────────────────────────────────────────────────
    local models = stats.models or {}
    if #models == 0 then
      push("  No model data for this period.")
      push("")
      return lines, hls
    end

    local BAR_W = 20
    local max_t = models[1].tokens
    local NAME_W = 30
    local TOK_W = 10

    push("  " .. rpad("Model", NAME_W) .. rpad("Tokens", TOK_W) .. "Calls")
    push("  " .. string.rep("─", W - 4))

    for _, model in ipairs(models) do
      local sname = short_model_name(model.name)
      local pct = max_t > 0 and (model.tokens / max_t * 100) or 0
      local b = bar(pct, BAR_W)
      push("  " .. rpad(sname, NAME_W) .. rpad(fmt_num(model.tokens), TOK_W) .. fmt_num(model.calls))
      local bar_lnum = #lines
      push("  " .. string.rep(" ", NAME_W) .. b)
      table.insert(hls, { lnum = bar_lnum, col = 2 + NAME_W, len = #b, hl = "ClaudeStatsBar" })
      push("")
    end
  end

  return lines, hls
end

-- ── popup state ───────────────────────────────────────────────────────────

local _winid = nil
local _bufnr = nil
local _autocmd = nil
local _tab = "overview"
local _filter = "all"
local _stats_cache = {}
local _loading = {}
local _ns = nil

local function close()
  if _autocmd then
    pcall(vim.api.nvim_del_autocmd, _autocmd)
    _autocmd = nil
  end
  if _winid and vim.api.nvim_win_is_valid(_winid) then
    vim.api.nvim_win_close(_winid, true)
  end
  _winid = nil
  _bufnr = nil
end

local function apply_hls(bufnr, hls)
  if not _ns then
    _ns = vim.api.nvim_create_namespace("claudecode_stats")
  end
  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_add_highlight, bufnr, _ns, h.hl, h.lnum, h.col, h.col + h.len)
  end
end

local function redraw()
  if not _bufnr or not vim.api.nvim_buf_is_valid(_bufnr) then
    return
  end
  local stats = _stats_cache[_filter]
  local lines, hls = build_lines(_tab, _filter, stats)
  for i, l in ipairs(lines) do
    local w = sdw(l)
    if w < W then
      lines[i] = l .. string.rep(" ", W - w)
    end
  end
  vim.bo[_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(_bufnr, 0, -1, false, lines)
  vim.bo[_bufnr].modifiable = false
  apply_hls(_bufnr, hls)
  if _winid and vim.api.nvim_win_is_valid(_winid) then
    local height = #lines
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - W) / 2)
    vim.api.nvim_win_set_config(_winid, {
      relative = "editor",
      width = W,
      height = height,
      row = row,
      col = col,
    })
  end
end

local function load_stats(filter)
  if _stats_cache[filter] ~= nil or _loading[filter] then
    return
  end
  _loading[filter] = true
  vim.schedule(function()
    local ok, stats_mod = pcall(require, "claudecode.stats")
    if ok then
      local result = stats_mod.compute(filter)
      _stats_cache[filter] = result or {}
    else
      _stats_cache[filter] = {}
    end
    _loading[filter] = nil
    redraw()
  end)
end

local function set_filter(f)
  _filter = f
  load_stats(f)
  redraw()
end

local function set_tab(t)
  _tab = t
  redraw()
end

-- ── public API ────────────────────────────────────────────────────────────

function M.toggle()
  if _winid and vim.api.nvim_win_is_valid(_winid) then
    close()
    return
  end

  setup_highlights()
  _stats_cache = {}
  _loading = {}

  _bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[_bufnr].bufhidden = "wipe"
  vim.bo[_bufnr].filetype = "claudestats"

  local lines, hls = build_lines(_tab, _filter, nil)
  for i, l in ipairs(lines) do
    local w = sdw(l)
    if w < W then
      lines[i] = l .. string.rep(" ", W - w)
    end
  end
  vim.api.nvim_buf_set_lines(_bufnr, 0, -1, false, lines)
  vim.bo[_bufnr].modifiable = false

  local height = #lines
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - W) / 2)
  _winid = vim.api.nvim_open_win(_bufnr, true, {
    relative = "editor",
    width = W,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
  })
  vim.api.nvim_set_option_value("winhl", "Normal:Normal,FloatBorder:FloatBorder", { win = _winid })
  apply_hls(_bufnr, hls)

  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = _bufnr, nowait = true, silent = true })
  end
  map("q", close)
  map("<Esc>", close)
  map("o", function()
    set_tab("overview")
  end)
  map("m", function()
    set_tab("models")
  end)
  map("a", function()
    set_filter("all")
  end)
  map("3", function()
    set_filter("30d")
  end)
  map("7", function()
    set_filter("7d")
  end)

  vim.schedule(function()
    if not _winid then
      return
    end
    _autocmd = vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
      callback = function()
        if vim.api.nvim_get_current_win() ~= _winid then
          close()
        end
      end,
    })
  end)

  load_stats(_filter)
end

return M