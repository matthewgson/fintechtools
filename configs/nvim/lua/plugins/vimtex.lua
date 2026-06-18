-- vimtex.lua — LazyVim drop-in plugin spec, synced to CIRCE by sync_configs.sh
-- into ~/.config/nvim/lua/plugins/.  Augments the LazyVim `lang.tex` extra
-- (which installs lervag/vimtex) with this container's HPC / SSH viewer wiring.
--
-- VIEWER: sioyek over X11 (native synctex).  sioyek is installed INSIDE the
-- container (Dockerfile Stage 5e) and renders to the Mac's XQuartz over the SSH
-- X11 forward that connect_nvim.sh adds (`-Y`).  Because nvim and sioyek run on
-- the same machine (the compute node), VimTeX's `sioyek` backend gives true
-- synctex both ways:
--   * forward search  <localleader>lv  → jump sioyek to the cursor's PDF spot
--   * inverse search  (click in sioyek) → jump nvim to the source line
-- Inverse search is just a local `nvim --server <v:servername> …` call that
-- VimTeX wires up automatically for method = "sioyek" — no cross-machine bridge.
--
-- This is the deliberate replacement for the old `general`/`mac-open` viewer,
-- which shipped a *copy* of the PDF to the Mac and therefore lost synctex.
-- `mac_open.lua` still handles non-TeX PDFs (snacks-explorer `o`, `gx`, yazi):
-- those keep opening on the Mac so casual browsing works without XQuartz.
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
      vim.g.vimtex_view_method = "sioyek"
      -- PATH wrapper from Dockerfile Stage 5e (forces Qt xcb + no MIT-SHM).
      vim.g.vimtex_view_sioyek_exe = "sioyek"
    end,
  },
}
