require("tests.busted_setup")

describe("session: cwd utilities", function()
  local session

  before_each(function()
    package.loaded["claudecode.session"] = nil
    -- Mock vim functions
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.fn.resolve = spy.new(function(p) return p end)
    _G.vim.fn.fnamemodify = spy.new(function(p, mod)
      if mod == ":p" then
        return p:sub(-1) == "/" and p or (p .. "/")
      end
      return p
    end)
    _G.vim.fn.stdpath = spy.new(function(what)
      if what == "data" then return "/tmp/nvim-test-data" end
      return "/tmp"
    end)
    _G.vim.fn.expand = spy.new(function(p)
      return p:gsub("^~", "/home/user")
    end)
    _G.vim.fn.mkdir = spy.new(function() return 1 end)
    _G.vim.loop = _G.vim.loop or {}
    _G.vim.loop.fs_opendir = spy.new(function() return nil end)
    _G.vim.loop.fs_stat = spy.new(function() return nil end)
    _G.vim.json = _G.vim.json or {}
    _G.vim.json.encode = spy.new(function(t) return "{}" end)
    _G.vim.json.decode = spy.new(function(s) return {} end)
    session = require("claudecode.session")
    session.setup({ enabled = true })
  end)

  it("canonical_cwd strips trailing slash", function()
    local result = session._canonical_cwd("/foo/bar/")
    expect(result).to_be("/foo/bar")
  end)

  it("canonical_cwd on path without trailing slash is unchanged", function()
    local result = session._canonical_cwd("/foo/bar")
    expect(result).to_be("/foo/bar")
  end)

  it("hash_cwd replaces slashes with dashes", function()
    local result = session._hash_cwd("/Users/foo/myproject")
    expect(result).to_be("-Users-foo-myproject")
  end)

  it("list_sessions returns empty table when projects dir does not exist", function()
    _G.vim.loop.fs_opendir = spy.new(function() return nil end)
    local results = session._list_sessions("/Users/foo/myproject")
    expect(results).to_be_table()
    assert.are.equal(0, #results)
  end)

  it("list_sessions returns empty table when dir has no jsonl files", function()
    local handle = {}
    local call_count = 0
    _G.vim.loop.fs_opendir = spy.new(function() return handle end)
    -- Iterator: first call returns batch, second returns nil (end)
    _G.vim.loop.fs_readdir = spy.new(function(h)
      call_count = call_count + 1
      if call_count == 1 then
        return { { name = "somefile.txt", type = "file" } }
      end
      return nil
    end)
    _G.vim.loop.fs_closedir = spy.new(function() end)
    local results = session._list_sessions("/Users/foo/myproject")
    assert.are.equal(0, #results)
  end)

  it("list_sessions returns sessions sorted newest first", function()
    local handle = {}
    local read_count = 0
    _G.vim.loop.fs_opendir = spy.new(function() return handle end)
    -- Iterator: first call returns all entries, second call returns nil
    _G.vim.loop.fs_readdir = spy.new(function()
      read_count = read_count + 1
      if read_count == 1 then
        return {
          { name = "aaa-old.jsonl", type = "file" },
          { name = "bbb-new.jsonl", type = "file" },
        }
      end
      return nil
    end)
    _G.vim.loop.fs_closedir = spy.new(function() end)
    _G.vim.loop.fs_stat = spy.new(function(path)
      if path:find("aaa") then
        return { mtime = { sec = 1000 } }
      end
      return { mtime = { sec = 2000 } }
    end)
    -- Mock io.open to return no preview
    local orig_io_open = io.open
    io.open = function() return nil end
    local results = session._list_sessions("/Users/foo/myproject")
    io.open = orig_io_open
    assert.are.equal(2, #results)
    assert.are.equal("bbb-new", results[1].id)
    assert.are.equal("aaa-old", results[2].id)
  end)

  it("list_sessions skips files where fs_stat returns nil", function()
    local handle = {}
    local read_count = 0
    _G.vim.loop.fs_opendir = spy.new(function() return handle end)
    -- Iterator pattern
    _G.vim.loop.fs_readdir = spy.new(function()
      read_count = read_count + 1
      if read_count == 1 then
        return { { name = "gone.jsonl", type = "file" } }
      end
      return nil
    end)
    _G.vim.loop.fs_closedir = spy.new(function() end)
    _G.vim.loop.fs_stat = spy.new(function() return nil end)
    local results = session._list_sessions("/Users/foo/myproject")
    assert.are.equal(0, #results)
  end)
end)

describe("session: JSONL preview parsing", function()
  local session

  before_each(function()
    package.loaded["claudecode.session"] = nil
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.fn.resolve = spy.new(function(p) return p end)
    _G.vim.fn.fnamemodify = spy.new(function(p, mod)
      if mod == ":p" then return p:sub(-1) == "/" and p or p .. "/" end
      if mod == ":h" then return p:match("(.+)/[^/]+$") or p end
      return p
    end)
    _G.vim.fn.stdpath = spy.new(function() return "/tmp/nvim-test-data" end)
    _G.vim.fn.expand = spy.new(function(p) return p end)
    _G.vim.fn.mkdir = spy.new(function() return 1 end)
    _G.vim.loop = { fs_opendir = spy.new(function() return nil end), fs_stat = spy.new(function() return nil end) }
    _G.vim.json = {}
    _G.vim.json.encode = spy.new(function(t) return "{}" end)
    _G.vim.json.decode = function(s)
      -- Minimal real decode for tests
      return _G.json_decode(s)
    end
    session = require("claudecode.session")
    session.setup({ enabled = true })
  end)

  it("returns (no preview) when file cannot be opened", function()
    local result = session._parse_session_preview("/nonexistent/file.jsonl")
    expect(result).to_be("(no preview)")
  end)

  it("extracts text from user message with table content", function()
    local lines = {
      '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Hello world"}]}}',
    }
    local orig_open = io.open
    io.open = function(path, mode)
      local i = 0
      return {
        lines = function() return function() i = i + 1; return lines[i] end end,
        close = function() end,
      }
    end
    local result = session._parse_session_preview("/fake.jsonl")
    io.open = orig_open
    expect(result).to_be("Hello world")
  end)

  it("extracts text from user message with string content", function()
    local lines = {
      '{"type":"user","message":{"role":"user","content":"Direct string message"}}',
    }
    local orig_open = io.open
    io.open = function()
      local i = 0
      return {
        lines = function() return function() i = i + 1; return lines[i] end end,
        close = function() end,
      }
    end
    local result = session._parse_session_preview("/fake.jsonl")
    io.open = orig_open
    expect(result).to_be("Direct string message")
  end)

  it("returns last user message when multiple present", function()
    local lines = {
      '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"First"}]}}',
      '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reply"}]}}',
      '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Second question"}]}}',
    }
    local orig_open = io.open
    io.open = function()
      local i = 0
      return {
        lines = function() return function() i = i + 1; return lines[i] end end,
        close = function() end,
      }
    end
    local result = session._parse_session_preview("/fake.jsonl")
    io.open = orig_open
    expect(result).to_be("Second question")
  end)

  it("truncates preview at 60 chars with ellipsis", function()
    local long = string.rep("a", 70)
    local lines = {
      '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"' .. long .. '"}]}}',
    }
    local orig_open = io.open
    io.open = function()
      local i = 0
      return {
        lines = function() return function() i = i + 1; return lines[i] end end,
        close = function() end,
      }
    end
    local result = session._parse_session_preview("/fake.jsonl")
    io.open = orig_open
    expect(#result).to_be(63) -- 60 + "..."
    assert_contains(result, "...")
  end)

  it("skips invalid JSON lines without error", function()
    local lines = {
      "not valid json {{{",
      '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Good line"}]}}',
    }
    local orig_open = io.open
    io.open = function()
      local i = 0
      return {
        lines = function() return function() i = i + 1; return lines[i] end end,
        close = function() end,
      }
    end
    local result = session._parse_session_preview("/fake.jsonl")
    io.open = orig_open
    expect(result).to_be("Good line")
  end)

  it("returns (no preview) when no user messages found", function()
    local lines = {
      '{"type":"assistant","message":{"role":"assistant","content":"Hello"}}',
    }
    local orig_open = io.open
    io.open = function()
      local i = 0
      return {
        lines = function() return function() i = i + 1; return lines[i] end end,
        close = function() end,
      }
    end
    local result = session._parse_session_preview("/fake.jsonl")
    io.open = orig_open
    expect(result).to_be("(no preview)")
  end)
end)

describe("session: preferences file", function()
  local session
  local fake_prefs_path = "/tmp/test-sessions.json"

  before_each(function()
    package.loaded["claudecode.session"] = nil
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.fn.resolve = spy.new(function(p) return p end)
    _G.vim.fn.fnamemodify = spy.new(function(p, mod)
      if mod == ":p" then return p:sub(-1) == "/" and p or p .. "/" end
      if mod == ":h" then return p:match("(.+)/[^/]+$") or p end
      return p
    end)
    _G.vim.fn.stdpath = spy.new(function() return "/tmp/nvim-test-data" end)
    _G.vim.fn.expand = spy.new(function(p) return p end)
    _G.vim.fn.mkdir = spy.new(function() return 1 end)
    _G.vim.loop = {
      fs_opendir = spy.new(function() return nil end),
      fs_stat = spy.new(function() return nil end),
      fs_open = spy.new(function() return nil end),
      fs_write = spy.new(function() return true end),
      fs_close = spy.new(function() end),
      fs_rename = spy.new(function() return true end),
    }
    _G.vim.json = {}
    _G.vim.json.encode = function(t) return _G.json_encode(t) end
    _G.vim.json.decode = function(s) return _G.json_decode(s) end
    session = require("claudecode.session")
    session.setup({ enabled = true })
  end)

  it("get_last_session_id returns nil when prefs file does not exist", function()
    -- io.open returning nil simulates missing file
    local orig_open = io.open
    io.open = function(path, mode) return nil end
    local result = session._get_last_session_id("/Users/foo/project")
    io.open = orig_open
    assert.is_nil(result)
  end)

  it("get_last_session_id returns id from prefs file", function()
    local prefs_content = '{ "/Users/foo/project": { "last_session_id": "abc-123", "updated_at": "2026-01-01" } }'
    local orig_open = io.open
    io.open = function(path, mode)
      if mode == "r" then
        return {
          read = function(self, fmt) return prefs_content end,
          close = function() end,
        }
      end
      return nil
    end
    local result = session._get_last_session_id("/Users/foo/project")
    io.open = orig_open
    expect(result).to_be("abc-123")
  end)

  it("get_last_session_id returns nil for cwd not in prefs", function()
    local prefs_content = '{ "/other/project": { "last_session_id": "xyz" } }'
    local orig_open = io.open
    io.open = function(path, mode)
      if mode == "r" then
        return {
          read = function(self, fmt) return prefs_content end,
          close = function() end,
        }
      end
      return nil
    end
    local result = session._get_last_session_id("/Users/foo/project")
    io.open = orig_open
    assert.is_nil(result)
  end)

  it("get_last_session_id returns nil on malformed JSON", function()
    local orig_open = io.open
    io.open = function(path, mode)
      if mode == "r" then
        return {
          read = function(self, fmt) return "not json {{{{" end,
          close = function() end,
        }
      end
      return nil
    end
    local result = session._get_last_session_id("/Users/foo/project")
    io.open = orig_open
    assert.is_nil(result)
  end)

  it("save_last_session_id writes prefs via atomic rename", function()
    local orig_open = io.open
    io.open = function(path, mode)
      if mode == "r" then return nil end -- no existing prefs
      return nil
    end
    io.open = orig_open
    _G.vim.loop.fs_open = spy.new(function() return 42 end) -- return fake fd
    session._save_last_session_id("/Users/foo/project", "new-session-id")
    assert.spy(_G.vim.loop.fs_open).was_called()
    assert.spy(_G.vim.loop.fs_rename).was_called()
  end)
end)

describe("session: public API", function()
  local session
  local ui_select_calls = {}
  local ui_select_choice = nil -- what vim.ui.select will "pick"

  before_each(function()
    package.loaded["claudecode.session"] = nil
    ui_select_calls = {}
    ui_select_choice = nil
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.fn.resolve = spy.new(function(p) return p end)
    _G.vim.fn.fnamemodify = spy.new(function(p, mod)
      if mod == ":p" then return p:sub(-1) == "/" and p or p .. "/" end
      if mod == ":h" then return p:match("(.+)/[^/]+$") or p end
      return p
    end)
    _G.vim.fn.stdpath = spy.new(function() return "/tmp/nvim-test-data" end)
    _G.vim.fn.expand = spy.new(function(p) return p end)
    _G.vim.fn.mkdir = spy.new(function() return 1 end)
    _G.vim.loop = {
      fs_opendir = spy.new(function() return nil end),
      fs_stat = spy.new(function() return nil end),
      fs_open = spy.new(function() return 42 end),
      fs_write = spy.new(function() return true end),
      fs_close = spy.new(function() end),
      fs_rename = spy.new(function() return true end),
    }
    _G.vim.json = {}
    _G.vim.json.encode = function(t) return _G.json_encode(t) end
    _G.vim.json.decode = function(s) return _G.json_decode(s) end
    _G.vim.ui = _G.vim.ui or {}
    _G.vim.ui.select = spy.new(function(items, opts, cb)
      table.insert(ui_select_calls, { items = items, opts = opts })
      if ui_select_choice ~= nil then
        -- Find index of choice
        for i, item in ipairs(items) do
          if item == ui_select_choice then
            cb(item, i)
            return
          end
        end
        cb(nil, nil) -- not found = cancel
      else
        cb(nil, nil) -- nil choice = cancel
      end
    end)
    session = require("claudecode.session")
    session.setup({ enabled = true })
  end)

  it("setup sets is_setup flag", function()
    expect(session.is_setup).to_be_true()
  end)

  it("reset clears in-memory skip flags", function()
    -- First resolve to set the skip flag
    local orig_open = io.open
    io.open = function() return nil end
    local callback_result
    session.resolve_args("/foo/project", function(args) callback_result = args end)
    io.open = orig_open
    -- skip flag now set (start fresh path)
    -- reset
    session.reset()
    -- After reset, is_setup is false
    expect(session.is_setup).to_be_false()
  end)

  it("resolve_args calls back with nil immediately when disabled", function()
    session.setup({ enabled = false })
    local callback_result = "not-called"
    session.resolve_args("/foo/project", function(args) callback_result = args end)
    assert.is_nil(callback_result)
  end)

  it("resolve_args calls back with nil immediately when no sessions exist", function()
    -- No sessions = no jsonl files; no prefs = no last_session_id
    local orig_open = io.open
    io.open = function() return nil end -- no prefs file
    local callback_result = "not-called"
    session.resolve_args("/foo/project", function(args) callback_result = args end)
    io.open = orig_open
    assert.is_nil(callback_result)
    assert.are.equal(0, #ui_select_calls) -- no picker shown
  end)

  it("resolve_args calls back with false on cancel when last_id exists", function()
    -- Has a last_session_id so picker is shown
    local prefs_content = '{ "/foo/project": { "last_session_id": "abc-123" } }'
    local orig_open = io.open
    io.open = function(path, mode)
      if mode == "r" then
        return { read = function() return prefs_content end, close = function() end }
      end
      return nil
    end
    ui_select_choice = nil -- user cancels
    local callback_result = "not-called"
    session.resolve_args("/foo/project", function(args) callback_result = args end)
    io.open = orig_open
    assert.are.equal(false, callback_result)
  end)

  it("resolve_args skips prompt and calls nil when skip flag is set", function()
    -- Manually set skip flag by calling resolve_args with no sessions first
    local orig_open = io.open
    io.open = function() return nil end
    session.resolve_args("/foo/project", function() end) -- sets skip flag
    io.open = orig_open

    -- Now should skip without showing picker
    ui_select_calls = {}
    local callback_result = "not-called"
    session.resolve_args("/foo/project", function(args) callback_result = args end)
    assert.is_nil(callback_result)
    assert.are.equal(0, #ui_select_calls)
  end)

  it("resolve_args shows only Start fresh and Choose session when sessions exist but no last_id", function()
    -- No saved last_session_id
    local orig_open = io.open
    io.open = function() return nil end -- no prefs file
    -- But sessions exist: mock _list_sessions to return one entry
    local orig_list = session._list_sessions
    session._list_sessions = function()
      return { { id = "abc-123", timestamp = 1000, preview = "Hello", formatted = "2026-01-01  \"Hello\"" } }
    end
    local shown_items
    _G.vim.ui.select = spy.new(function(items, opts, cb)
      shown_items = items
      cb(nil, nil) -- cancel
    end)
    session.resolve_args("/foo/project", function() end)
    io.open = orig_open
    session._list_sessions = orig_list
    assert.are.equal(2, #shown_items) -- only "Start fresh" and "Choose session..."
    expect(shown_items[1]).to_match("Start fresh")
    expect(shown_items[2]).to_match("Choose session")
    -- No "Restore last session" option
    for _, item in ipairs(shown_items) do
      assert.is_false(item:find("Restore last session") ~= nil)
    end
  end)

  it("resolve_args returns --resume id when restore last session chosen", function()
    local prefs_content = '{ "/foo/project": { "last_session_id": "abc-123" } }'
    local orig_open = io.open
    io.open = function(path, mode)
      if mode == "r" then
        return { read = function() return prefs_content end, close = function() end }
      end
      return nil
    end
    ui_select_choice = nil
    -- We need to pick the second item which contains "Restore last session"
    _G.vim.ui.select = spy.new(function(items, opts, cb)
      -- Find restore item
      for i, item in ipairs(items) do
        if item:find("Restore last session") then
          cb(item, i)
          return
        end
      end
      cb(nil, nil)
    end)
    local callback_result = "not-called"
    session.resolve_args("/foo/project", function(args) callback_result = args end)
    io.open = orig_open
    expect(callback_result).to_be("--resume abc-123")
  end)

  it("resolve_args returns nil and sets skip flag when start fresh chosen", function()
    local prefs_content = '{ "/foo/project": { "last_session_id": "abc-123" } }'
    local orig_open = io.open
    io.open = function(path, mode)
      if mode == "r" then
        return { read = function() return prefs_content end, close = function() end }
      end
      return nil
    end
    _G.vim.ui.select = spy.new(function(items, opts, cb)
      cb(items[1], 1) -- always pick first = "Start fresh"
    end)
    local callback_result = "not-called"
    session.resolve_args("/foo/project", function(args) callback_result = args end)
    io.open = orig_open
    assert.is_nil(callback_result)
    -- skip flag should now prevent future prompts
    local second_result = "not-called"
    local second_ui_calls = 0
    _G.vim.ui.select = spy.new(function(items, opts, cb)
      second_ui_calls = second_ui_calls + 1
      cb(nil, nil)
    end)
    session.resolve_args("/foo/project", function(args) second_result = args end)
    assert.are.equal(0, second_ui_calls) -- no picker shown second time
    assert.is_nil(second_result)
  end)
end)

describe("session: terminal integration", function()
  local terminal
  local session_resolve_args_calls
  local session_resolve_args_callback_args -- what resolve_args will pass to callback

  before_each(function()
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.server.init"] = nil

    session_resolve_args_calls = {}
    session_resolve_args_callback_args = nil -- nil = start fresh by default

    -- Mock server module (required by terminal.lua at module load)
    package.loaded["claudecode.server.init"] = { state = { port = nil } }

    -- Mock session module
    local mock_session = {
      is_setup = true,
      resolve_args = function(cwd, cb)
        table.insert(session_resolve_args_calls, cwd)
        cb(session_resolve_args_callback_args)
      end,
    }
    package.loaded["claudecode.session"] = mock_session

    -- Mock vim functions
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.fn.getcwd = spy.new(function() return "/fake/project" end)
    _G.vim.api = _G.vim.api or {}
    _G.vim.api.nvim_buf_is_valid = spy.new(function(bufnr) return false end) -- fresh open

    terminal = require("claudecode.terminal")
    terminal.setup(nil, nil, nil)
  end)

  it("simple_toggle calls session.resolve_args on fresh open with no cmd_args", function()
    local provider_calls = {}
    local mock_provider = {
      get_active_bufnr = function() return nil end, -- fresh open
      simple_toggle = function(cmd, env, cfg)
        table.insert(provider_calls, { cmd = cmd })
      end,
      focus_toggle = function() end,
      open = function() end,
      close = function() end,
      setup = function() end,
      is_available = function() return true end,
    }
    terminal.setup({ provider = mock_provider }, nil, nil)

    terminal.simple_toggle({}, nil)

    assert.are.equal(1, #session_resolve_args_calls)
    assert.are.equal(1, #provider_calls)
    assert.are.equal("claude", provider_calls[1].cmd)
  end)

  it("simple_toggle bypasses session prompt when cmd_args provided", function()
    local provider_calls = {}
    local mock_provider = {
      get_active_bufnr = function() return nil end,
      simple_toggle = function(cmd, env, cfg)
        table.insert(provider_calls, { cmd = cmd })
      end,
      focus_toggle = function() end,
      open = function() end,
      close = function() end,
      setup = function() end,
      is_available = function() return true end,
    }
    terminal.setup({ provider = mock_provider }, nil, nil)

    terminal.simple_toggle({}, "--resume abc-123")

    assert.are.equal(0, #session_resolve_args_calls) -- no session prompt
    assert.are.equal(1, #provider_calls)
    assert_contains(provider_calls[1].cmd, "--resume abc-123")
  end)

  it("simple_toggle bypasses session prompt when terminal already exists", function()
    local provider_calls = {}
    local mock_provider = {
      get_active_bufnr = function() return 42 end, -- existing buffer
      simple_toggle = function(cmd, env, cfg)
        table.insert(provider_calls, { cmd = cmd })
      end,
      focus_toggle = function() end,
      open = function() end,
      close = function() end,
      setup = function() end,
      is_available = function() return true end,
    }
    _G.vim.api.nvim_buf_is_valid = spy.new(function(bufnr) return true end) -- valid = not fresh
    terminal.setup({ provider = mock_provider }, nil, nil)

    terminal.simple_toggle({}, nil) -- trigger the toggle

    assert.are.equal(0, #session_resolve_args_calls) -- session prompt NOT shown
    assert.are.equal(1, #provider_calls) -- terminal toggle did fire
  end)

  it("simple_toggle does not open terminal when session resolve returns false (cancel)", function()
    session_resolve_args_callback_args = false -- user cancelled
    local provider_calls = {}
    local mock_provider = {
      get_active_bufnr = function() return nil end,
      simple_toggle = function(cmd, env, cfg)
        table.insert(provider_calls, { cmd = cmd })
      end,
      focus_toggle = function() end,
      open = function() end,
      close = function() end,
      setup = function() end,
      is_available = function() return true end,
    }
    terminal.setup({ provider = mock_provider }, nil, nil)

    terminal.simple_toggle({}, nil)

    assert.are.equal(1, #session_resolve_args_calls)
    assert.are.equal(0, #provider_calls) -- terminal NOT opened
  end)

  it("focus_toggle also calls session.resolve_args on fresh open", function()
    local provider_calls = {}
    local mock_provider = {
      get_active_bufnr = function() return nil end,
      simple_toggle = function() end,
      focus_toggle = function(cmd, env, cfg)
        table.insert(provider_calls, { cmd = cmd })
      end,
      open = function() end,
      close = function() end,
      setup = function() end,
      is_available = function() return true end,
    }
    terminal.setup({ provider = mock_provider }, nil, nil)

    terminal.focus_toggle({}, nil)

    assert.are.equal(1, #session_resolve_args_calls)
    assert.are.equal(1, #provider_calls)
  end)
end)
