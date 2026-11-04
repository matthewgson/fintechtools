-- pdf_open.lua — LazyVim drop-in plugin spec, synced to CIRCE by
-- build_container.sh into ~/.config/nvim/lua/plugins/.  LazyVim auto-loads
-- every file under lua/plugins/, so no further wiring is needed.
--
-- Routes vim.ui.open (gx, the snacks explorer's `o`, and many other "open
-- externally" callsites):
--   * PDFs open in farleaf (terminal reader, in a herdr split via
--     farleaf-split).
--   * HTML files and http(s) URLs open in Safari on the Mac via mac-open,
--     through the tunnels connect_nvim.sh sets up (see ~/.local/bin/mac-open).
--     The container has no browser, so the default handler (xdg-open) had
--     nothing to give them to.
-- Everything else falls back to the previous opener.

local function mac_open(target)
  local ok, obj = pcall(vim.system, { "mac-open", target }, { text = true }, function(r)
    if r.code ~= 0 then
      local msg = vim.trim((r.stderr or "") ~= "" and r.stderr or (r.stdout or ""))
      vim.schedule(function()
        vim.notify(msg ~= "" and msg or "mac-open failed", vim.log.levels.WARN)
      end)
    end
  end)
  if not ok then
    return nil, "mac-open: " .. tostring(obj)
  end
  return obj
end

return {
  {
    "LazyVim/LazyVim",
    init = function()
      local prev = vim.ui.open
      vim.ui.open = function(path, opt)
        if type(path) == "string" then
          local lower = path:lower()
          if lower:match("%.pdf$") then
            -- farleaf-split needs only HERDR_*, which nvim passes on.
            vim.system({ "farleaf-split", path })
            return { wait = function() return { code = 0 } end }
          end
          if lower:match("^https?://") or lower:match("%.x?html?$") then
            return mac_open(path)
          end
        end
        return prev and prev(path, opt)
      end
    end,
  },
}
