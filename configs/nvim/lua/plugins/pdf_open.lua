-- pdf_open.lua — LazyVim drop-in plugin spec, synced to CIRCE by
-- build_container.sh into ~/.config/nvim/lua/plugins/.  LazyVim auto-loads
-- every file under lua/plugins/, so no further wiring is needed.
--
-- Routes vim.ui.open (gx, and many other "open externally" callsites) so PDFs
-- open in bookokrat (terminal reader, in a tmux split via bookokrat-split).
-- Everything else falls back to the previous opener.  (This replaces the old
-- mac_open.lua, which shipped PDFs/HTML/images/URLs to a listener on the Mac;
-- that bridge has been removed.)

return {
  {
    "LazyVim/LazyVim",
    init = function()
      local prev = vim.ui.open
      vim.ui.open = function(path, opt)
        if type(path) == "string" and path:lower():match("%.pdf$") then
          vim.system({ "bookokrat-split", path })
          return { wait = function() return { code = 0 } end }
        end
        return prev and prev(path, opt)
      end
    end,
  },
}
