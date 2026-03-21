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
