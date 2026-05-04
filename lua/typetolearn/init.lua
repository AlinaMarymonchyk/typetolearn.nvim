-- typetolearn.nvim
-- Force yourself to type AI-suggested code changes instead of just accepting them.
-- Hooks into claudecode.nvim's diff acceptance to intercept changes.

local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("typetolearn")

M.active_session = nil
M.config = {}
M._hooked = false
M._diff_data = {}
M._file_snapshots = {}

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
        local id = api.nvim_buf_set_extmark(session.bufnr, ns, line_idx, session.current_col, {
          virt_text = { { remaining, M.config.ghost_hl } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
        table.insert(session.extmark_ids, id)
      end
    else
      if #line > 0 then
        local id = api.nvim_buf_set_extmark(session.bufnr, ns, line_idx, 0, {
          virt_text = { { line, M.config.ghost_hl } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })
        table.insert(session.extmark_ids, id)
      end
    end
  end
end

-- ============================================================================
-- Core: Start a typing session
-- ============================================================================

function M.start_session(bufnr, start_line, lines, opts)
  opts = opts or {}

  if M.active_session then
    M.cancel_session()
  end

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
    extmark_ids = {},
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

  local blank_lines = {}
  for _ = 1, #lines do
    table.insert(blank_lines, "")
  end
  api.nvim_buf_set_lines(bufnr, start_line, start_line, false, blank_lines)

  M._render_ghost_text(session)
  api.nvim_win_set_cursor(0, { start_line + 1, 0 })
  vim.cmd("startinsert")
  M._attach_key_handler(session)
  M._echo("Type the ghost text to accept. [Esc to skip]", "MoreMsg")
end

-- ============================================================================
-- Keystroke handling
-- ============================================================================

function M._attach_key_handler(session)
  local group = api.nvim_create_augroup("TypeToLearn", { clear = true })

  api.nvim_create_autocmd("InsertCharPre", {
    group = group,
    buffer = session.bufnr,
    callback = function()
      if not M.active_session then return end
      local char = vim.v.char
      vim.v.char = ""
      vim.schedule(function()
        M._handle_char(char)
      end)
    end,
  })

  M._map_special_keys(session)

  vim.keymap.set("i", "<Esc>", function()
    if M.active_session then
      M.skip_session()
    end
  end, { buffer = session.bufnr, noremap = true })
end

function M._map_special_keys(session)
  vim.keymap.set("i", "<CR>", function()
    if not M.active_session then return end
    M._handle_enter()
  end, { buffer = session.bufnr, noremap = true })

  vim.keymap.set("i", "<BS>", function()
    if not M.active_session then return end
    M._handle_backspace()
  end, { buffer = session.bufnr, noremap = true })

  vim.keymap.set("i", "<Tab>", function()
    if not M.active_session then return end
    local expandtab = vim.bo[session.bufnr].expandtab
    if expandtab then
      local sw = vim.bo[session.bufnr].shiftwidth
      if sw == 0 then sw = 4 end
      for _ = 1, sw do
        M._handle_char(" ")
      end
    else
      M._handle_char("\t")
    end
  end, { buffer = session.bufnr, noremap = true })
end

function M._handle_char(char)
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

    if s.current_col >= #expected_line then
      if s.current_line >= #s.lines - 1 then
        M._complete_session()
        return
      end
    end

    api.nvim_win_set_cursor(0, { buf_line + 1, s.current_col })
    M._render_ghost_text(s)
  else
    s.errors = s.errors + 1
    M._flash_error(s)
  end
end

function M._handle_enter()
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
    M._render_ghost_text(s)
  else
    M._flash_error(s)
  end
end

function M._handle_backspace()
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
    M._render_ghost_text(s)
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
  M._snapshot_buf(s.bufnr)
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
  M._snapshot_buf(s.bufnr)
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

function M._snapshot_buf(bufnr)
  local name = api.nvim_buf_get_name(bufnr)
  if name ~= "" then
    M._file_snapshots[name] = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
end

function M._reload_from_disk(file_path)
  if not file_path or file_path == "" then return end
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) == file_path then
      if api.nvim_buf_is_loaded(buf) then
        api.nvim_buf_call(buf, function()
          vim.cmd("edit!")
        end)
      end
      break
    end
  end
end

-- ============================================================================
-- Intercept a change: revert buffer to old, show ghost text for typing
-- ============================================================================

function M._on_buffer_changed(file_path, old_lines, new_lines)
  if M.active_session then return end
  if not file_path or file_path == "" then return end

  -- Safety: if old_lines is empty but file exists on disk, try reading from disk
  if #old_lines == 0 then
    local f = io.open(file_path, "r")
    if f then
      local content = f:read("*a")
      f:close()
      -- File exists but we have no old content — disk now has new content
      -- so we can't recover old content. Treat as new file.
      vim.notify("[type-to-learn] No old content captured, treating as new file", vim.log.levels.DEBUG)
    end
  end

  local ok_diff, hunks = pcall(M._compute_diff, old_lines, new_lines)
  if not ok_diff then
    vim.notify("[type-to-learn] Diff computation failed: " .. tostring(hunks), vim.log.levels.WARN)
    return
  end

  local add_hunks = {}
  for _, hunk in ipairs(hunks) do
    if #hunk.new_lines > 0 then
      table.insert(add_hunks, hunk)
    end
  end

  if #add_hunks == 0 then
    M._file_snapshots[file_path] = new_lines
    return
  end

  -- Find buffer
  local bufnr = nil
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) == file_path then
      bufnr = buf
      break
    end
  end

  if not bufnr then
    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    bufnr = api.nvim_get_current_buf()
  end

  if not api.nvim_buf_is_loaded(bufnr) then
    vim.fn.bufload(bufnr)
  end

  -- Reload from disk first so buffer is in sync
  pcall(api.nvim_buf_call, bufnr, function()
    vim.cmd("edit!")
  end)

  -- Focus buffer window
  local win_id = nil
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == bufnr then
      win_id = win
      break
    end
  end
  if win_id then
    api.nvim_set_current_win(win_id)
  else
    vim.cmd("edit " .. vim.fn.fnameescape(file_path))
    bufnr = api.nvim_get_current_buf()
  end

  -- Revert buffer to old content
  api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  api.nvim_buf_set_lines(bufnr, 0, -1, false, old_lines)

  -- Process hunks sequentially.
  -- Buffer starts with old content. Each hunk has old_start (position in old file).
  -- As we process hunks, line positions shift by cumulative delta from prior hunks.
  local cumulative_delta = 0
  local function process_hunk(idx)
    if idx > #add_hunks then
      M._echo("All changes typed!", "MoreMsg")
      M._snapshot_buf(bufnr)
      pcall(function()
        api.nvim_buf_call(bufnr, function()
          vim.cmd("silent! write!")
        end)
      end)
      return
    end

    local hunk = add_hunks[idx]
    -- old_start is where these lines are in the original old file (0-indexed)
    -- Adjust for cumulative changes from prior hunks
    local buf_pos = (hunk.old_start or hunk.start_line) + cumulative_delta

    if #hunk.old_lines > 0 then
      local remove_end = buf_pos + #hunk.old_lines
      local buf_total = api.nvim_buf_line_count(bufnr)
      if buf_pos < buf_total then
        remove_end = math.min(remove_end, buf_total)
        pcall(api.nvim_buf_set_lines, bufnr, buf_pos, remove_end, false, {})
      end
    end

    -- After removing old and typing new, delta changes by (new_count - old_count)
    local this_delta = #hunk.new_lines - #hunk.old_lines
    cumulative_delta = cumulative_delta + this_delta

    M.start_session(bufnr, buf_pos, hunk.new_lines, {
      on_complete = function()
        vim.defer_fn(function()
          process_hunk(idx + 1)
        end, 300)
      end,
    })
  end

  M._echo(string.format("Claude edited %s — type %d change(s)!", vim.fn.fnamemodify(file_path, ":t"), #add_hunks), "MoreMsg")
  process_hunk(1)
end

-- ============================================================================
-- Hook into claudecode.nvim
-- ============================================================================

function M._hook_claudecode()
  if M._hooked then return end

  local ok, claude_diff = pcall(require, "claudecode.diff")
  if not ok then return end
  if not claude_diff._register_diff_state or not claude_diff.close_diff_by_tab_name then
    return
  end

  M._hooked = true
  M._echo("Hooked into claudecode.nvim!", "MoreMsg")

  -- Capture diff data when claudecode registers a diff
  local original_register = claude_diff._register_diff_state
  claude_diff._register_diff_state = function(tab_name, diff_data)
    -- Read old file content NOW from disk (NOT buffer — buffer might be the diff view)
    local old_lines = {}
    if diff_data.old_file_path then
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

    -- Parse new content into lines
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
    vim.notify(string.format("[type-to-learn] Captured diff: old=%d lines, new=%d lines, path=%s",
      #old_lines, #new_lines, diff_data.old_file_path or "nil"), vim.log.levels.INFO)
    return original_register(tab_name, diff_data)
  end

  -- Intercept when CLI accepts (close_tab → close_diff_by_tab_name)
  local original_close = claude_diff.close_diff_by_tab_name
  claude_diff.close_diff_by_tab_name = function(tab_name)
    local captured = M._diff_data[tab_name]
    M._diff_data[tab_name] = nil

    local result = original_close(tab_name)

    if captured and captured.old_file_path and not captured._handled then
      vim.defer_fn(function()
        -- Check if file actually changed on disk (accept vs reject)
        local disk_lines = M._read_file(captured.old_file_path)
        local changed = #disk_lines ~= #captured.old_lines
        if not changed then
          for i = 1, #disk_lines do
            if disk_lines[i] ~= captured.old_lines[i] then
              changed = true
              break
            end
          end
        end
        if changed then
          M._on_buffer_changed(captured.old_file_path, captured.old_lines, captured.new_lines)
        end
      end, 500)
    end

    return result
  end

  -- Intercept when user accepts via :w in nvim diff view
  local original_resolve = claude_diff._resolve_diff_as_saved
  claude_diff._resolve_diff_as_saved = function(tab_name, buffer_id)
    local captured = M._diff_data[tab_name]
    if captured then
      captured._handled = true
    end

    original_resolve(tab_name, buffer_id)

    if captured then
      M._diff_data[tab_name] = nil
      vim.defer_fn(function()
        M._on_buffer_changed(captured.old_file_path, captured.old_lines, captured.new_lines)
      end, 800)
    end
  end
end

-- ============================================================================
-- File watcher fallback (for files that bypass diff view)
-- ============================================================================

function M._start_file_watching()
  local group = api.nvim_create_augroup("TypeToLearnWatch", { clear = true })

  api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    callback = function(ev)
      if not M.active_session then
        M._snapshot_buf(ev.buf)
      end
    end,
  })

  api.nvim_create_autocmd("FileChangedShellPost", {
    group = group,
    callback = function(ev)
      if M.active_session then return end
      local filepath = api.nvim_buf_get_name(ev.buf)
      if filepath == "" then return end
      local old_lines = M._file_snapshots[filepath]
      if not old_lines then return end
      local new_lines = api.nvim_buf_get_lines(ev.buf, 0, -1, false)
      M._file_snapshots[filepath] = nil
      vim.defer_fn(function()
        M._on_buffer_changed(filepath, old_lines, new_lines)
      end, 100)
    end,
  })

  api.nvim_create_autocmd({ "FocusGained", "CursorHold" }, {
    group = group,
    callback = function()
      if not M.active_session then
        vim.cmd("silent! checktime")
      end
    end,
  })
end

-- ============================================================================
-- Commands
-- ============================================================================

function M._register_commands()
  api.nvim_create_user_command("TypeToLearnDemo", function()
    local bufnr = api.nvim_get_current_buf()
    local cursor = api.nvim_win_get_cursor(0)
    M.start_session(bufnr, cursor[1] - 1, {
      "def hello(name: str) -> None:",
      '    print(f"Hello, {name}")',
      "",
      "hello('world')",
    })
  end, { desc = "Run a demo" })

  api.nvim_create_user_command("TypeToLearnSkip", function()
    M.skip_session()
  end, { desc = "Skip current session" })

  api.nvim_create_user_command("TypeToLearnCancel", function()
    M.cancel_session()
  end, { desc = "Cancel current session" })

  api.nvim_create_user_command("TypeToLearnSnapshot", function()
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
        M._snapshot_buf(bufnr)
      end
    end
    M._echo("Snapshots updated", "MoreMsg")
  end, { desc = "Re-snapshot all buffers" })
end

-- ============================================================================
-- Setup
-- ============================================================================

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})
  M._register_commands()

  -- Always start file watcher
  M._start_file_watching()

  -- Hook claudecode.nvim
  M._hook_claudecode()

  if not M._hooked then
    vim.defer_fn(function() M._hook_claudecode() end, 1000)
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

  -- Initial snapshot of all loaded buffers
  vim.defer_fn(function()
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
        M._snapshot_buf(bufnr)
      end
    end
  end, 500)
end

return M
