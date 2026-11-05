-- Container-only (synced to CIRCE by sync_configs.sh, never to the Mac): yanks
-- reach the Mac clipboard over OSC 52.
--
-- Without this, every yank stayed inside nvim. LazyVim sets
-- clipboard=unnamedplus unless $SSH_CONNECTION is set, and udocker does not
-- pass that variable into the container. nvim picks its OSC 52 provider by
-- itself only while 'clipboard' is empty, and the node has no
-- xclip/xsel/wl-copy (no display either), so the clipboard provider resolved to
-- nothing. Seen 2026-11-05 in both running nvims: termfeatures.osc52 = true
-- (herdr reports OSC 52 support), clipboard = unnamedplus, provider = "".
--
-- Copy: OSC 52 from nvim to herdr, which passes it on to Ghostty because there
-- is no DISPLAY, and Ghostty writes the Mac clipboard. Ghostty allows that by
-- default, and herdr caps one write at 192 KB.
-- Paste: nvim's own record of the last yank, NOT an OSC 52 read. With
-- unnamedplus every `p` would otherwise ask the terminal for the Mac
-- clipboard, which Ghostty prompts for or refuses, and nvim waits up to 10 s.
-- To paste text copied on the Mac, use Cmd-V (the terminal's own paste).
local osc52 = require("vim.ui.clipboard.osc52")
local last = {} ---@type table<string, table>

local function copy(reg)
  local send = osc52.copy(reg)
  return function(lines, regtype)
    last[reg] = { lines, regtype }
    send(lines)
  end
end

local function paste(reg)
  return function()
    return last[reg] or { {}, "v" }
  end
end

vim.g.clipboard = {
  name = "OSC 52 copy (to the Mac), local paste",
  copy = { ["+"] = copy("+"), ["*"] = copy("*") },
  paste = { ["+"] = paste("+"), ["*"] = paste("*") },
}

-- In case anything loaded the clipboard provider before this spec ran, reload
-- it so it picks up g:clipboard (`:h g:clipboard`).
if vim.g.loaded_clipboard_provider then
  vim.g.loaded_clipboard_provider = nil
  vim.cmd("runtime autoload/provider/clipboard.vim")
end

return {}
