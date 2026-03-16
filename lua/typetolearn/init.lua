-- typetolearn.nvim
-- Force yourself to type AI-suggested code changes instead of just accepting them.
-- Hooks into claudecode.nvim's diff acceptance to intercept changes.

local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("typetolearn")

M.active_session = nil
M.config = {}
M._hooked = false

-- Debug log to file (temporary — remove after debugging)
local _log_file = "/tmp/typetolearn_debug.log"
local function _dbg(msg)
  local f = io.open(_log_file, "a")
  if f then
    f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
    f:close()
  end
end

local defaults = {
  ghost_hl = "Comment",
  error_hl = "DiagnosticError",
}

-- ============================================================================
-- Diff: use vim.diff for reliable hunk computation
-- ============================================================================

function M._compute_hunks(old_lines, new_lines)
  if #old_lines == 0 then
    return { { old_start = 0, old_count = 0, new_start = 0, new_lines = new_lines } }
  end

  local old_text = table.concat(old_lines, "\n") .. "\n"
  local new_text = table.concat(new_lines, "\n") .. "\n"
  local indices = vim.diff(old_text, new_text, { result_type = "indices" })

  local hunks = {}
  for _, idx in ipairs(indices) do
    local start_a, count_a, start_b, count_b = idx[1], idx[2], idx[3], idx[4]
    local hunk_new_lines = {}
    for i = start_b, start_b + count_b - 1 do
      table.insert(hunk_new_lines, new_lines[i])
    end
    table.insert(hunks, {
      old_start = start_a - 1,
      old_count = count_a,
      new_start = start_b - 1,
      new_lines = hunk_new_lines,
    })
  end
  return hunks
end

-- ============================================================================
-- Ghost text rendering (on blank lines — buffer has "" where user types)
-- ============================================================================

function M._render_ghost(session)
  api.nvim_buf_clear_namespace(session.bufnr, ns, 0, -1)

  for i, line in ipairs(session.lines) do
    local line_idx = session.start_line + i - 1
    local is_current = (i - 1 == session.current_line)
    local is_done = (i - 1 < session.current_line)

    if is_done then
      -- already typed into buffer
    elseif is_current then
      local remaining = line:sub(session.current_col + 1)
      if #remaining > 0 then
        api.nvim_buf_set_extmark(session.bufnr, ns, line_idx, session.current_col, {
          virt_text = { { remaining, M.config.ghost_hl } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
      end
    else
      if #line > 0 then
        api.nvim_buf_set_extmark(session.bufnr, ns, line_idx, 0, {
          virt_text = { { line, M.config.ghost_hl } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
      end
    end
  end
end

-- ============================================================================
-- Typing session (blank-out approach: lines are blanked, user types to fill)
-- ============================================================================

function M.start_session(bufnr, start_line, lines, opts)
  opts = opts or {}

  if M.active_session then
    M.cancel_session()
  end

  -- Trim trailing empty lines
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  if #lines == 0 then
    if opts.on_complete then opts.on_complete() end
    return
  end

  local session = {
    bufnr = bufnr,
    lines = lines,
    start_line = start_line,
    current_line = 0,
    current_col = 0,
    on_complete = opts.on_complete or function() end,
    total_chars = 0,
    typed_chars = 0,
    errors = 0,
  }

  for _, line in ipairs(lines) do
    session.total_chars = session.total_chars + #line + 1
  end

  M.active_session = session

  api.nvim_set_option_value("modifiable", true, { buf = bufnr })

  -- Blank lines if not already blanked by caller
  if not opts.lines_already_blank then
    local blank_lines = {}
    for _ = 1, #lines do
      table.insert(blank_lines, "")
    end
    api.nvim_buf_set_lines(bufnr, start_line, start_line, false, blank_lines)
  end

  M._render_ghost(session)
  api.nvim_win_set_cursor(0, { start_line + 1, 0 })
  vim.cmd("startinsert")
  M._attach_keys(session)
  M._echo("Type the ghost text. [Esc] to skip.", "MoreMsg")
end

-- ============================================================================
-- Key handling
-- ============================================================================

function M._attach_keys(session)
  local group = api.nvim_create_augroup("TypeToLearn", { clear = true })

  api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = session.bufnr,
    callback = function()
      if M.active_session and M.active_session.bufnr == session.bufnr then
        local buf_line = session.start_line + session.current_line
        pcall(api.nvim_win_set_cursor, 0, { buf_line + 1, session.current_col })
        vim.schedule(function()
          if M.active_session then vim.cmd("startinsert") end
        end)
      end
    end,
  })

  api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    buffer = session.bufnr,
    callback = function()
      if not M.active_session then return end
      local char = vim.v.char
      vim.v.char = ""
      vim.schedule(function()
        M._on_char(char)
      end)
    end,
  })

  vim.keymap.set("i", "<CR>", function()
    if M.active_session then M._on_enter() end
  end, { buffer = session.bufnr, noremap = true })

  vim.keymap.set("i", "<BS>", function()
    if M.active_session then M._on_backspace() end
  end, { buffer = session.bufnr, noremap = true })

  vim.keymap.set("i", "<Tab>", function()
    if not M.active_session then return end
    local sw = vim.bo[session.bufnr].shiftwidth
    if sw == 0 then sw = 4 end
    if vim.bo[session.bufnr].expandtab then
      for _ = 1, sw do M._on_char(" ") end
    else
      M._on_char("\t")
    end
  end, { buffer = session.bufnr, noremap = true })

  vim.keymap.set("i", "<Esc>", function()
    if M.active_session then M.skip_session() end
  end, { buffer = session.bufnr, noremap = true })
end

function M._on_char(char)
  local s = M.active_session
  if not s then return end

  local expected_line = s.lines[s.current_line + 1]
  if not expected_line then return end

  local expected_char = expected_line:sub(s.current_col + 1, s.current_col + 1)

  if char == expected_char then
    local buf_line = s.start_line + s.current_line
    local current_text = api.nvim_buf_get_lines(s.bufnr, buf_line, buf_line + 1, false)[1] or ""
    api.nvim_buf_set_lines(s.bufnr, buf_line, buf_line + 1, false, { current_text .. char })
    s.current_col = s.current_col + 1
    s.typed_chars = s.typed_chars + 1

    if s.current_col >= #expected_line and s.current_line >= #s.lines - 1 then
      M._complete_session()
      return
    end

    api.nvim_win_set_cursor(0, { buf_line + 1, s.current_col })
    M._render_ghost(s)
  else
    s.errors = s.errors + 1
    M._flash_error(s)
  end
end

function M._on_enter()
  local s = M.active_session
  if not s then return end
  local expected_line = s.lines[s.current_line + 1]

  if s.current_col >= #expected_line then
    s.current_line = s.current_line + 1
    s.current_col = 0
    s.typed_chars = s.typed_chars + 1

    if s.current_line >= #s.lines then
      M._complete_session()
      return
    end

    local buf_line = s.start_line + s.current_line
    api.nvim_win_set_cursor(0, { buf_line + 1, 0 })
    M._render_ghost(s)
  else
    M._flash_error(s)
  end
end

function M._on_backspace()
  local s = M.active_session
  if not s then return end
  if s.current_col > 0 then
    s.current_col = s.current_col - 1
    local buf_line = s.start_line + s.current_line
    local current_text = api.nvim_buf_get_lines(s.bufnr, buf_line, buf_line + 1, false)[1] or ""
    if #current_text > 0 then
      api.nvim_buf_set_lines(s.bufnr, buf_line, buf_line + 1, false, { current_text:sub(1, -2) })
    end
    api.nvim_win_set_cursor(0, { buf_line + 1, math.max(0, s.current_col) })
    M._render_ghost(s)
  end
end

-- ============================================================================
-- Session lifecycle
-- ============================================================================

function M._complete_session()
  local s = M.active_session
  if not s then return end
  _dbg("COMPLETE_SESSION: bufnr=" .. s.bufnr .. " line=" .. s.current_line .. "/" .. #s.lines)
  M._cleanup(s)
  local accuracy = s.typed_chars > 0 and math.floor((s.typed_chars / (s.typed_chars + s.errors)) * 100) or 0
  M._echo(string.format("Done! %d chars, %d errors, %d%% accuracy", s.typed_chars, s.errors, accuracy), "MoreMsg")
  s.on_complete()
  M.active_session = nil
end

function M.skip_session()
  local s = M.active_session
  if not s then return end
  -- Fill in remaining content
  for i = s.current_line, #s.lines - 1 do
    local buf_line = s.start_line + i
    api.nvim_buf_set_lines(s.bufnr, buf_line, buf_line + 1, false, { s.lines[i + 1] })
  end
  M._cleanup(s)
  M._echo("Skipped — changes applied.", "WarningMsg")
  s.on_complete()
  M.active_session = nil
end

function M.cancel_session()
  local s = M.active_session
  if not s then return end
  -- Fill in content (don't revert — disk already has new content)
  for i = s.current_line, #s.lines - 1 do
    local buf_line = s.start_line + i
    api.nvim_buf_set_lines(s.bufnr, buf_line, buf_line + 1, false, { s.lines[i + 1] })
  end
  M._cleanup(s)
  M._echo("Cancelled — changes applied.", "WarningMsg")
  M.active_session = nil
end

-- Force-finish the session: fill in remaining text, write, clear modified.
-- Used when a new diff comes in during an active typing session.
function M._force_finish_session()
  local s = M.active_session
  if not s then return end
  _dbg("FORCE_FINISH: filling in remaining text")
  -- Fill in all remaining lines
  for i = s.current_line, #s.lines - 1 do
    local buf_line = s.start_line + i
    pcall(api.nvim_buf_set_lines, s.bufnr, buf_line, buf_line + 1, false, { s.lines[i + 1] })
  end
  M._cleanup(s)
  -- Write to disk (noautocmd to avoid save hooks trimming lines)
  pcall(api.nvim_buf_call, s.bufnr, function()
    vim.cmd("silent! noautocmd write!")
    vim.cmd("filetype detect")
  end)
  M.active_session = nil
end

function M._cleanup(session)
  api.nvim_buf_clear_namespace(session.bufnr, ns, 0, -1)
  pcall(api.nvim_del_augroup_by_name, "TypeToLearn")
  pcall(vim.keymap.del, "i", "<CR>", { buffer = session.bufnr })
  pcall(vim.keymap.del, "i", "<BS>", { buffer = session.bufnr })
  pcall(vim.keymap.del, "i", "<Tab>", { buffer = session.bufnr })
  pcall(vim.keymap.del, "i", "<Esc>", { buffer = session.bufnr })
  vim.cmd("stopinsert")
end

function M._flash_error(session)
  local buf_line = session.start_line + session.current_line
  local col = session.current_col
  local ok, id = pcall(api.nvim_buf_set_extmark, session.bufnr, ns, buf_line, col, {
    end_col = col + 1,
    hl_group = M.config.error_hl,
    priority = 200,
  })
  if ok then
    vim.defer_fn(function()
      pcall(api.nvim_buf_del_extmark, session.bufnr, ns, id)
    end, 200)
  end
end

function M._echo(msg, hl)
  api.nvim_echo({ { "[type-to-learn] " .. msg, hl or "Normal" } }, true, {})
end

-- ============================================================================
-- Hook into claudecode.nvim
-- ============================================================================

function M._hook_claudecode()
  if M._hooked then return end

  local ok, claude_diff = pcall(require, "claudecode.diff")
  if not ok then return end

  if not claude_diff.open_diff_blocking or not claude_diff.close_diff_by_tab_name then
    return
  end

  M._hooked = true
  M._echo("Hooked into claudecode.nvim!", "MoreMsg")

  M._diff_data = {}

  -- Patch open_diff_blocking: capture data AND force-finish any active session
  -- so the buffer is clean for claudecode's dirty-buffer check.
  local original_open = claude_diff.open_diff_blocking
  claude_diff.open_diff_blocking = function(old_file_path, new_file_path, new_file_contents, tab_name)
    _dbg("OPEN_DIFF: tab=" .. tostring(tab_name) .. " path=" .. tostring(old_file_path))

    -- KEY FIX: If we have an active typing session, finish it NOW
    -- (fills in remaining text, writes to disk, clears modified flag).
    -- This prevents the "Cannot create diff: file has unsaved changes" error.
    if M.active_session then
      _dbg("OPEN_DIFF: force-finishing active session before new diff")
      pcall(M._force_finish_session)
    end

    -- Capture diff data (read old from disk AFTER finishing session, so it's current)
    pcall(function()
      local old_lines = {}
      if old_file_path then
        local f = io.open(old_file_path, "r")
        if f then
          local content = f:read("*a")
          f:close()
          old_lines = vim.split(content, "\n")
          if #old_lines > 0 and old_lines[#old_lines] == "" then
            table.remove(old_lines)
          end
        end
      end

      local new_lines = {}
      if new_file_contents then
        new_lines = vim.split(new_file_contents, "\n")
        if #new_lines > 0 and new_lines[#new_lines] == "" then
          table.remove(new_lines)
        end
      end

      M._diff_data[tab_name] = {
        old_file_path = old_file_path,
        old_lines = old_lines,
        new_lines = new_lines,
      }
      _dbg("OPEN_DIFF_CAPTURED: old=" .. #old_lines .. " new=" .. #new_lines)
    end)

    return original_open(old_file_path, new_file_path, new_file_contents, tab_name)
  end

  -- Patch close_diff_by_tab_name
  local original_close = claude_diff.close_diff_by_tab_name
  claude_diff.close_diff_by_tab_name = function(tab_name)
    _dbg("CLOSE: tab=" .. tostring(tab_name) .. " has_data=" .. tostring(M._diff_data[tab_name] ~= nil))
    local captured = nil
    pcall(function()
      captured = M._diff_data[tab_name]
      M._diff_data[tab_name] = nil
    end)

    local result = original_close(tab_name)

    _dbg("CLOSE_AFTER: captured=" .. tostring(captured ~= nil)
      .. " accepted_in_nvim=" .. tostring(captured and captured._accepted_in_nvim))

    if captured and captured.old_file_path and not captured._accepted_in_nvim then
      vim.defer_fn(function()
        pcall(function()
          -- Check if disk actually changed (accept vs reject)
          local f = io.open(captured.old_file_path, "r")
          if not f then
            if #captured.new_lines > 0 then
              M._intercept_change(captured.old_file_path, captured.old_lines, captured.new_lines)
            end
            return
          end
          local disk_content = f:read("*a")
          f:close()
          local disk_lines = vim.split(disk_content, "\n")
          if #disk_lines > 0 and disk_lines[#disk_lines] == "" then
            table.remove(disk_lines)
          end

          local changed = #disk_lines ~= #captured.old_lines
          if not changed then
            for idx = 1, #disk_lines do
              if disk_lines[idx] ~= captured.old_lines[idx] then
                changed = true
                break
              end
            end
          end

          _dbg("CLOSE_DISK_CHECK: disk_lines=" .. #disk_lines .. " old_lines=" .. #captured.old_lines .. " changed=" .. tostring(changed))
          if changed then
            M._intercept_change(captured.old_file_path, captured.old_lines, captured.new_lines)
          else
            -- Disk unchanged = diff setup failed (CLI didn't write).
            -- Don't write to disk (would cause "unexpectedly modified" error).
            -- Instead, intercept and set buffer content directly in _intercept_change.
            _dbg("CLOSE_FALLBACK: intercepting without disk write")
            M._intercept_change(captured.old_file_path, captured.old_lines, captured.new_lines)
          end
        end)
      end, 300)
    end

    return result
  end

  -- Patch _resolve_diff_as_saved
  local original_resolve = claude_diff._resolve_diff_as_saved
  claude_diff._resolve_diff_as_saved = function(tab_name, buffer_id)
    _dbg("RESOLVE_SAVED: tab=" .. tostring(tab_name) .. " has_data=" .. tostring(M._diff_data[tab_name] ~= nil))
    local captured = nil
    pcall(function()
      captured = M._diff_data[tab_name]
      if captured then captured._accepted_in_nvim = true end
    end)

    original_resolve(tab_name, buffer_id)

    if captured then
      pcall(function() M._diff_data[tab_name] = nil end)
      vim.defer_fn(function()
        pcall(function()
          M._intercept_change(captured.old_file_path, captured.old_lines, captured.new_lines)
        end)
      end, 800)
    end
  end
end

-- ============================================================================
-- Intercept a change: blank changed lines, show ghost text for typing
-- ============================================================================

function M._intercept_change(file_path, old_lines, new_lines)
  _dbg("INTERCEPT: path=" .. tostring(file_path) .. " old=" .. #old_lines .. " new=" .. #new_lines
    .. " active_session=" .. tostring(M.active_session ~= nil))
  if not file_path then return end
  if #old_lines == 0 and #new_lines == 0 then return end

  -- If there's an active session, force-finish it
  if M.active_session then
    if not api.nvim_buf_is_valid(M.active_session.bufnr) then
      M.active_session = nil
    else
      M._force_finish_session()
    end
  end

  -- Compute hunks
  local diff_ok, hunks = pcall(M._compute_hunks, old_lines, new_lines)
  if not diff_ok then
    M._echo("Diff error: " .. tostring(hunks), "ErrorMsg")
    return
  end

  local type_hunks = {}
  for _, hunk in ipairs(hunks) do
    if #hunk.new_lines > 0 then
      table.insert(type_hunks, hunk)
    end
  end
  if #type_hunks == 0 then return end

  local function find_normal_window()
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(win) then
        local buf = api.nvim_win_get_buf(win)
        local bt = vim.bo[buf].buftype
        local cfg = api.nvim_win_get_config(win)
        local is_float = cfg.relative and cfg.relative ~= ""
        if not is_float and bt ~= "terminal" and bt ~= "nofile" then
          return win
        end
      end
    end
    return nil
  end

  -- Find or open the buffer
  local target_bufnr = vim.fn.bufnr(file_path)
  if target_bufnr == -1 or not api.nvim_buf_is_valid(target_bufnr) then
    local normal_win = find_normal_window()
    if normal_win then api.nvim_set_current_win(normal_win) end
    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    target_bufnr = api.nvim_get_current_buf()
  end

  if not api.nvim_buf_is_loaded(target_bufnr) then
    vim.fn.bufload(target_bufnr)
  end

  -- Reload from disk to get the NEW content Claude wrote
  pcall(api.nvim_buf_call, target_bufnr, function()
    vim.cmd("silent! edit!")
  end)

  -- Verify buffer line count matches expected new content
  local buf_line_count = api.nvim_buf_line_count(target_bufnr)
  _dbg("BUFFER_LINES: " .. buf_line_count .. " expected=" .. #new_lines)

  -- If buffer doesn't match new_lines, set it directly
  if buf_line_count ~= #new_lines then
    _dbg("BUFFER_MISMATCH: setting buffer to new_lines directly (" .. buf_line_count .. " -> " .. #new_lines .. ")")
    api.nvim_set_option_value("modifiable", true, { buf = target_bufnr })
    api.nvim_buf_set_lines(target_bufnr, 0, -1, false, new_lines)
  end

  -- Focus the buffer's window
  local win_id = nil
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == target_bufnr then
      win_id = win
      break
    end
  end
  if win_id then
    api.nvim_set_current_win(win_id)
  else
    local normal_win = find_normal_window()
    if normal_win then api.nvim_set_current_win(normal_win) end
    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    target_bufnr = api.nvim_get_current_buf()
  end

  api.nvim_set_option_value("modifiable", true, { buf = target_bufnr })

  -- Build type_ranges: split hunks into sub-ranges of contiguous non-empty lines
  local type_ranges = {}
  for _, hunk in ipairs(type_hunks) do
    local i = 1
    while i <= #hunk.new_lines do
      if hunk.new_lines[i] == "" then
        i = i + 1
      else
        local range_start = i
        local range_lines = {}
        while i <= #hunk.new_lines and hunk.new_lines[i] ~= "" do
          table.insert(range_lines, hunk.new_lines[i])
          i = i + 1
        end
        table.insert(type_ranges, {
          new_start = hunk.new_start + range_start - 1,
          new_lines = range_lines,
        })
      end
    end
  end

  if #type_ranges == 0 then return end

  -- Blank out only the non-empty lines in the buffer
  for _, range in ipairs(type_ranges) do
    local blanks = {}
    for _ = 1, #range.new_lines do
      table.insert(blanks, "")
    end
    pcall(api.nvim_buf_set_lines, target_bufnr,
      range.new_start, range.new_start + #range.new_lines, false, blanks)
  end

  -- Process ranges sequentially
  local function process_range(idx)
    if idx > #type_ranges then
      -- All done — restore full content, write to disk, clear modified
      _dbg("ALL_RANGES_DONE: restoring full content and writing")
      api.nvim_buf_set_lines(target_bufnr, 0, -1, false, new_lines)
      pcall(api.nvim_buf_call, target_bufnr, function()
        vim.cmd("silent! noautocmd write!")
        vim.cmd("filetype detect")
      end)
      M._echo("All changes typed!", "MoreMsg")
      return
    end

    local range = type_ranges[idx]
    M.start_session(target_bufnr, range.new_start, range.new_lines, {
      lines_already_blank = true,
      on_complete = function()
        vim.defer_fn(function()
          process_range(idx + 1)
        end, 300)
      end,
    })
  end

  M._echo(
    string.format("Type %d change(s) for %s", #type_ranges, vim.fn.fnamemodify(file_path, ":t")),
    "MoreMsg"
  )
  process_range(1)
end

-- ============================================================================
-- Fallback: file watching
-- ============================================================================

function M._start_file_watching()
  M._file_snapshots = {}

  local group = api.nvim_create_augroup("TypeToLearnWatch", { clear = true })

  api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      if not M.active_session then
        local name = api.nvim_buf_get_name(ev.buf)
        if name ~= "" then
          M._file_snapshots[name] = api.nvim_buf_get_lines(ev.buf, 0, -1, false)
        end
      end
    end,
  })

  api.nvim_create_autocmd("FileChangedShellPost", {
    group = group,
    callback = function(ev)
      vim.defer_fn(function()
        if M.active_session then return end
        local filepath = api.nvim_buf_get_name(ev.buf)
        local old_lines = M._file_snapshots[filepath]
        if not old_lines then return end
        local new_lines = api.nvim_buf_get_lines(ev.buf, 0, -1, false)
        M._file_snapshots[filepath] = nil
        M._intercept_change(filepath, old_lines, new_lines)
      end, 100)
    end,
  })

  api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if not M.active_session then vim.cmd("silent! checktime") end
    end,
  })
end

-- ============================================================================
-- Commands
-- ============================================================================

function M._register_commands()
  api.nvim_create_user_command("TypeToLearnSkip", function()
    M.skip_session()
  end, { desc = "Skip current typing session" })

  api.nvim_create_user_command("TypeToLearnCancel", function()
    M.cancel_session()
  end, { desc = "Cancel current typing session" })

  api.nvim_create_user_command("TypeToLearnDemo", function()
    local bufnr = api.nvim_get_current_buf()
    local cursor = api.nvim_win_get_cursor(0)
    M.start_session(bufnr, cursor[1] - 1, {
      "def hello(name: str) -> None:",
      '    print(f"Hello, {name}")',
      "",
      "hello('world')",
    })
  end, { desc = "Run a typing demo" })
end

-- ============================================================================
-- Setup
-- ============================================================================

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
  M._register_commands()
  M._start_file_watching()
  M._hook_claudecode()

  if not M._hooked then
    for _, delay in ipairs({ 500, 1000, 2000, 5000 }) do
      vim.defer_fn(function()
        if not M._hooked then M._hook_claudecode() end
      end, delay)
    end

    local retry_group = api.nvim_create_augroup("TypeToLearnRetry", { clear = true })
    api.nvim_create_autocmd("User", {
      group = retry_group,
      pattern = "LazyLoad",
      callback = function()
        if not M._hooked then
          vim.defer_fn(function() M._hook_claudecode() end, 200)
        end
        if M._hooked then
          pcall(api.nvim_del_augroup_by_name, "TypeToLearnRetry")
          return true
        end
      end,
    })
    api.nvim_create_autocmd({ "VimEnter", "BufEnter" }, {
      group = retry_group,
      callback = function()
        if not M._hooked then M._hook_claudecode() end
        if M._hooked then
          pcall(api.nvim_del_augroup_by_name, "TypeToLearnRetry")
          return true
        end
      end,
    })
  end
end

return M
