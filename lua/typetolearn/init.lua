-- typetolearn.nvim
-- Force yourself to type AI-suggested code changes instead of just accepting them.
-- Hooks into claudecode.nvim's diff acceptance to intercept changes.

local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("typetolearn")

M.active_session = nil
M.config = {}
M._hooked = false

local defaults = {
  ghost_hl = "Comment",
  error_hl = "DiagnosticError",
}

-- ============================================================================
-- Diff: use vim.diff for reliable hunk computation
-- ============================================================================

--- Compute hunks using neovim's built-in vim.diff (Myers algorithm).
--- Returns list of {start_line (0-indexed in old), count_old, count_new, new_lines}.
function M._compute_hunks(old_lines, new_lines)
  local old_text = table.concat(old_lines, "\n") .. "\n"
  local new_text = table.concat(new_lines, "\n") .. "\n"

  -- vim.diff with result_type="indices" returns list of {start_a, count_a, start_b, count_b}
  local indices = vim.diff(old_text, new_text, { result_type = "indices" })

  local hunks = {}
  for _, idx in ipairs(indices) do
    local start_a, count_a, start_b, count_b = idx[1], idx[2], idx[3], idx[4]
    -- Extract the new lines for this hunk
    local hunk_new_lines = {}
    for i = start_b, start_b + count_b - 1 do
      table.insert(hunk_new_lines, new_lines[i])
    end
    table.insert(hunks, {
      old_start = start_a - 1, -- convert to 0-indexed
      old_count = count_a,
      new_lines = hunk_new_lines,
    })
  end

  return hunks
end

-- ============================================================================
-- Ghost text rendering
-- ============================================================================

function M._render_ghost(session)
  api.nvim_buf_clear_namespace(session.bufnr, ns, 0, -1)

  for i, line in ipairs(session.lines) do
    local line_idx = session.start_line + i - 1
    local is_current = (i - 1 == session.current_line)
    local is_done = (i - 1 < session.current_line)

    if is_done then
      -- already typed
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
-- Typing session
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

  -- Insert blank lines where the new content should go
  local blank_lines = {}
  for _ = 1, #lines do
    table.insert(blank_lines, "")
  end
  api.nvim_buf_set_lines(bufnr, start_line, start_line, false, blank_lines)

  M._render_ghost(session)
  api.nvim_win_set_cursor(0, { start_line + 1, 0 })
  vim.cmd("startinsert")
  M._attach_keys(session)
  M._echo("Type the ghost text. [Esc] to skip remaining.", "MoreMsg")
end

-- ============================================================================
-- Key handling
-- ============================================================================

function M._attach_keys(session)
  local group = api.nvim_create_augroup("TypeToLearn", { clear = true })

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
  M._cleanup(s)
  local accuracy = s.typed_chars > 0 and math.floor((s.typed_chars / (s.typed_chars + s.errors)) * 100) or 0
  M._echo(string.format("Done! %d chars, %d errors, %d%% accuracy", s.typed_chars, s.errors, accuracy), "MoreMsg")
  s.on_complete()
  M.active_session = nil
end

function M.skip_session()
  local s = M.active_session
  if not s then return end
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
  api.nvim_buf_set_lines(s.bufnr, s.start_line, s.start_line + #s.lines, false, {})
  M._cleanup(s)
  M._echo("Cancelled — reverted.", "WarningMsg")
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
-- Reload buffer from disk (recovery helper)
-- ============================================================================

function M._reload_from_disk(file_path)
  local bufnr = vim.fn.bufnr(file_path)
  if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
    api.nvim_buf_call(bufnr, function()
      vim.cmd("edit!")
    end)
  end
end

-- ============================================================================
-- Hook into claudecode.nvim
-- ============================================================================

function M._hook_claudecode()
  if M._hooked then return end

  local ok, claude_diff = pcall(require, "claudecode.diff")
  if not ok then
    M._echo("claudecode.diff not found, using file watcher fallback", "WarningMsg")
    M._start_file_watching()
    return
  end

  if not claude_diff._register_diff_state or not claude_diff.close_diff_by_tab_name then
    M._echo("claudecode.diff API changed, using fallback", "WarningMsg")
    M._start_file_watching()
    return
  end

  M._hooked = true
  M._echo("Hooked into claudecode.nvim!", "MoreMsg")

  M._diff_data = {}

  -- Capture diff data when claudecode registers a diff
  local original_register = claude_diff._register_diff_state
  claude_diff._register_diff_state = function(tab_name, diff_data)
    -- Read old file content from buffer (more reliable than io.open)
    local old_lines = {}
    if diff_data.old_file_path then
      local bufnr = vim.fn.bufnr(diff_data.old_file_path)
      if bufnr ~= -1 and api.nvim_buf_is_loaded(bufnr) then
        old_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
      else
        local f = io.open(diff_data.old_file_path, "r")
        if f then
          local content = f:read("*a")
          f:close()
          old_lines = vim.split(content, "\n")
          if #old_lines > 0 and old_lines[#old_lines] == "" then
            table.remove(old_lines)
          end
        end
      end
    end

    -- Parse new content
    local new_lines = {}
    if diff_data.new_file_contents then
      new_lines = vim.split(diff_data.new_file_contents, "\n")
      if #new_lines > 0 and new_lines[#new_lines] == "" then
        table.remove(new_lines)
      end
    end

    M._diff_data[tab_name] = {
      old_file_path = diff_data.old_file_path,
      old_lines = old_lines,
      new_lines = new_lines,
    }
    return original_register(tab_name, diff_data)
  end

  -- Patch close_diff_by_tab_name — called when CLI accepts via "Yes"
  local original_close = claude_diff.close_diff_by_tab_name
  claude_diff.close_diff_by_tab_name = function(tab_name)
    local captured = M._diff_data[tab_name]
    M._diff_data[tab_name] = nil

    local result = original_close(tab_name)

    if captured and captured.old_file_path and not captured._accepted_in_nvim then
      vim.defer_fn(function()
        -- Check if file on disk actually changed (accept vs reject)
        local f = io.open(captured.old_file_path, "r")
        if not f then
          -- New file that was accepted
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

        -- Compare disk to old content
        local changed = #disk_lines ~= #captured.old_lines
        if not changed then
          for idx = 1, #disk_lines do
            if disk_lines[idx] ~= captured.old_lines[idx] then
              changed = true
              break
            end
          end
        end

        if changed then
          M._intercept_change(captured.old_file_path, captured.old_lines, captured.new_lines)
        end
      end, 300)
    end

    return result
  end

  -- Patch _resolve_diff_as_saved — called when user accepts via :w in nvim
  local original_resolve = claude_diff._resolve_diff_as_saved
  claude_diff._resolve_diff_as_saved = function(tab_name, buffer_id)
    local captured = M._diff_data[tab_name]
    if captured then
      captured._accepted_in_nvim = true
    end

    original_resolve(tab_name, buffer_id)

    if captured then
      M._diff_data[tab_name] = nil
      vim.defer_fn(function()
        M._intercept_change(captured.old_file_path, captured.old_lines, captured.new_lines)
      end, 800)
    end
  end
end

-- ============================================================================
-- Intercept a change: revert buffer, show ghost text for typing
-- ============================================================================

function M._intercept_change(file_path, old_lines, new_lines)
  if not file_path then return end
  if #old_lines == 0 and #new_lines == 0 then return end

  -- Compute hunks using vim.diff
  local diff_ok, hunks = pcall(M._compute_hunks, old_lines, new_lines)
  if not diff_ok then
    M._echo("Diff error, reloading file: " .. tostring(hunks), "ErrorMsg")
    M._reload_from_disk(file_path)
    return
  end

  -- Filter to hunks that have new lines (additions or replacements)
  local type_hunks = {}
  for _, hunk in ipairs(hunks) do
    if #hunk.new_lines > 0 then
      table.insert(type_hunks, hunk)
    end
  end

  if #type_hunks == 0 then
    M._reload_from_disk(file_path)
    return
  end

  -- Find or open the buffer
  local target_bufnr = vim.fn.bufnr(file_path)
  if target_bufnr == -1 then
    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    target_bufnr = api.nvim_get_current_buf()
  end

  if not api.nvim_buf_is_loaded(target_bufnr) then
    vim.fn.bufload(target_bufnr)
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
    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    target_bufnr = api.nvim_get_current_buf()
  end

  -- Set buffer to old content
  local set_ok = pcall(function()
    api.nvim_set_option_value("modifiable", true, { buf = target_bufnr })
    api.nvim_buf_set_lines(target_bufnr, 0, -1, false, old_lines)
  end)

  if not set_ok then
    M._echo("Failed to revert buffer, reloading from disk", "ErrorMsg")
    M._reload_from_disk(file_path)
    return
  end

  -- Process hunks sequentially, applying offset as we go
  -- Each hunk changes the buffer length, so later hunks need adjustment
  local offset = 0

  local function process_hunk(idx)
    if idx > #type_hunks then
      -- All done — save to disk
      pcall(function()
        api.nvim_buf_call(target_bufnr, function()
          vim.cmd("silent! write!")
        end)
      end)
      M._echo("All changes typed!", "MoreMsg")
      return
    end

    local hunk = type_hunks[idx]
    local adjusted_start = hunk.old_start + offset

    -- Remove old lines for this hunk (replacement)
    local remove_ok = true
    if hunk.old_count > 0 then
      remove_ok = pcall(api.nvim_buf_set_lines, target_bufnr,
        adjusted_start, adjusted_start + hunk.old_count, false, {})
    end

    if not remove_ok then
      M._echo("Error applying hunk, reloading from disk", "ErrorMsg")
      M._reload_from_disk(file_path)
      return
    end

    -- Track how many lines we're adding vs removing for offset
    local lines_added = #hunk.new_lines
    local lines_removed = hunk.old_count

    M.start_session(target_bufnr, adjusted_start, hunk.new_lines, {
      on_complete = function()
        offset = offset + lines_added - lines_removed
        vim.defer_fn(function()
          process_hunk(idx + 1)
        end, 300)
      end,
    })
  end

  M._echo(
    string.format("Type %d change(s) for %s", #type_hunks, vim.fn.fnamemodify(file_path, ":t")),
    "MoreMsg"
  )
  process_hunk(1)
end

-- ============================================================================
-- Fallback: file watching (for when claudecode.nvim is not available)
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

  -- Try to hook immediately
  M._hook_claudecode()

  -- Retry strategies for lazy-loaded claudecode.nvim
  if not M._hooked then
    vim.defer_fn(function()
      M._hook_claudecode()
    end, 1000)
  end

  if not M._hooked then
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
