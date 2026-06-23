-- vimtex.lua — LazyVim drop-in plugin spec, synced to CIRCE by sync_configs.sh
-- into ~/.config/nvim/lua/plugins/.  Augments the LazyVim `lang.tex` extra
-- (which installs lervag/vimtex) with this container's HPC / SSH viewer wiring.
--
-- VIEWER: bookokrat (terminal PDF reader, native synctex).  bookokrat is
-- installed INSIDE the container (Dockerfile Stage 5f) and draws the PDF inline
-- via the kitty graphics protocol, which ghostty renders straight over SSH — no
-- X11/XQuartz, no PDF copy shipped to the Mac.  Because nvim and bookokrat run
-- on the same machine (the compute node), synctex works both ways:
--   * forward search  <localleader>lv  → bookokrat-forward opens/jumps the PDF
--     (it launches bookokrat in a tmux split if no instance is running yet).
--   * inverse search  (gd / Ctrl-click in bookokrat) → bookokrat-inverse jumps
--     nvim to the source line via `nvim --server $NVIM`.  Inverse is wired in
--     ~/.config/bookokrat/config.yaml (synctex_editor: bookokrat-inverse …).
-- The bookokrat-forward/-split/-inverse wrappers ship to ~/.local/bin (on PATH
-- inside the container) via sync_configs.sh.
--
-- This replaces the previous sioyek-over-X11 viewer (removed) and the even
-- older `mac-open` viewer, which shipped a *copy* of the PDF to the Mac and
-- therefore lost synctex.  (The Mac-side `mac-open` bridge has since been
-- removed entirely; `pdf_open.lua` routes other PDF open callsites to bookokrat.)
--
-- Note: synctex must be emitted at compile time.  VimTeX's default latexmk
-- options already include `-synctex=1`, and TinyTeX's engines support it, so no
-- compiler override is needed here.
--
-- `optional = true` means we only add config — we don't pull VimTeX into the
-- plugin spec on its own.  The LazyVim `lang.tex` extra (or any other spec
-- that lists lervag/vimtex) is what actually installs it.

return {
  {
    "lervag/vimtex",
    optional = true,
    init = function()
      -- general viewer → bookokrat-forward <line> <col> <tex> <pdf>.
      vim.g.vimtex_view_method = "general"
      vim.g.vimtex_view_general_viewer = "bookokrat-forward"
      vim.g.vimtex_view_general_options = "@line @col @tex @pdf"
    end,
  },
}
