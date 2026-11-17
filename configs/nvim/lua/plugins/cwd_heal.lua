-- Container-only (synced to CIRCE by sync_configs.sh, never to the Mac): get
-- out of a working directory that a filesystem remount has killed.
--
-- 2026-11-12: RC restarted the Quobyte client on mdc-1057-13-13 under a running
-- session. Every process kept its cwd on the old, detached mount. In the nvim
-- started on 11-10 in 04_OptionsML, vim.uv.cwd() returned
-- "ENOTCONN: socket is not connected", getcwd() returned "", and scandir(".")
-- failed, so everything rooted at the cwd broke: the snacks explorer, lazygit
-- (<leader>gg), the pickers, :terminal. Absolute paths still worked, and nvim
-- still knew the right directory. So: when the cwd is gone, chdir() back into it
-- by name, through the live mount.
--
-- Where the name comes from, in order:
--   1. getcwd() for this window, when it is a window- or tab-local dir. nvim
--      keeps those as strings, so they survive the remount.
--   2. The last cwd this file saw working (polled, see below).
--   3. $PWD, which is the launching shell's directory, for an nvim started
--      from a pane whose cwd was already dead. zsh keeps $PWD as a name, and
--      that name still resolves.
--
-- Detection is one getcwd() every 3 s on a libuv timer. A remount gives no
-- event, and a timer catches it before the next keypress needs the cwd.
-- Nothing is scheduled while the cwd is fine. Also checked on FocusGained and
-- VimResume.
if vim.g.cwd_heal_loaded then
  return {}
end
vim.g.cwd_heal_loaded = true

local last = vim.uv.cwd()

local function heal()
  if vim.uv.cwd() then
    return
  end
  local cands = {}
  local ok, here = pcall(vim.fn.getcwd)
  if ok then
    cands[#cands + 1] = here
  end
  cands[#cands + 1] = last
  cands[#cands + 1] = vim.env.PWD
  for _, d in ipairs(cands) do
    if type(d) == "string" and d ~= "" and vim.fn.isdirectory(d) == 1 then
      -- chdir() keeps the scope (global, tab or window) of the dir it replaces.
      pcall(vim.fn.chdir, d)
      if vim.uv.cwd() then
        last = vim.uv.cwd()
        vim.notify("cwd was on a dead mount; re-entered " .. last, vim.log.levels.WARN)
        return
      end
    end
  end
end

-- At startup: nvim launched from a pane that was already on the dead mount.
heal()

local timer = vim.uv.new_timer()
if timer then
  timer:start(3000, 3000, function()
    local cwd = vim.uv.cwd()
    if cwd then
      last = cwd
    else
      vim.schedule(heal)
    end
  end)
  timer:unref()
end

vim.api.nvim_create_autocmd({ "FocusGained", "VimResume" }, {
  group = vim.api.nvim_create_augroup("cwd_heal", { clear = true }),
  callback = heal,
})

return {}
