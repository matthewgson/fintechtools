-- mac_open.lua — LazyVim drop-in plugin spec, synced to CIRCE by
-- build_container.sh into ~/.config/nvim/lua/plugins/.  LazyVim auto-loads
-- every file under lua/plugins/, so no further wiring is needed.
--
-- Reroutes vim.ui.open (used by snacks-explorer's `o` action, gx, and many
-- other "open externally" callsites) through the container's `mac-open`
-- helper for PDFs / HTML / images / URLs.  Anything else falls back to the
-- previous opener (xdg-open under the container's default).

local exts = {
  pdf = true, html = true, htm = true,
  png = true, jpg = true, jpeg = true, svg = true, gif = true,
}

return {
  {
    "LazyVim/LazyVim",
    init = function()
      local prev = vim.ui.open
      vim.ui.open = function(path, opt)
        if type(path) ~= "string" then
          return prev and prev(path, opt)
        end
        local ext = path:lower():match("%.([^.]+)$")
        local is_url = path:match("^https?://") ~= nil
        if (ext and exts[ext]) or is_url then
          vim.system({ "mac-open", path }, { detach = true })
          return { wait = function() return { code = 0 } end }
        end
        return prev and prev(path, opt)
      end
    end,
  },
}
