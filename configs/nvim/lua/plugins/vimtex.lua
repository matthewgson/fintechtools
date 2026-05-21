-- vimtex.lua — LazyVim drop-in plugin spec, synced to CIRCE by sync_configs.sh
-- into ~/.config/nvim/lua/plugins/.  Augments the LazyVim `lang.tex` extra
-- (which installs lervag/vimtex) with this container's HPC / SSH viewer wiring.
--
-- The container is headless, so VimTeX's default viewer (xdg-open via the
-- `general` method) goes nowhere.  Route `<localleader>lv` through the
-- `mac-open` bridge so PDFs open in the Mac's default viewer over the SSH
-- reverse tunnel established by connect_nvim.sh (`-R 8765:127.0.0.1:8765`).
--
-- This complements `mac_open.lua`, which already reroutes vim.ui.open for
-- snacks-explorer and `gx`; VimTeX has its own viewer config that bypasses
-- vim.ui.open, so it needs to be set separately.
--
-- `optional = true` means we only add config — we don't pull VimTeX into the
-- plugin spec on its own.  The LazyVim `lang.tex` extra (or any other spec
-- that lists lervag/vimtex) is what actually installs it.

return {
  {
    "lervag/vimtex",
    optional = true,
    init = function()
      vim.g.vimtex_view_method = "general"
      vim.g.vimtex_view_general_viewer = "mac-open"
      vim.g.vimtex_view_general_options = "@pdf"
    end,
  },
}
