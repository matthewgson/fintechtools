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
			-- ── Version guard override ────────────────────────────────────────────
			-- VimTeX only supports the CURRENT stable Vim/Neovim: its
			-- ftplugin/tex.vim aborts with
			--     Error: VimTeX does not support your version of Vim
			-- unless `has('nvim-0.12.4')` (or Vim 9.2). Under nvim 0.12 that echoerr
			-- kills the whole BufReadPost → FileType autocmd chain, so treesitter
			-- highlighting never attaches either — the .tex buffer opens uncolored.
			-- The container's nvim is pinned in the Dockerfile (ARG NVIM_VERSION) and
			-- is only rebuilt occasionally, so it lags whatever VimTeX HEAD demands.
			-- `vimtex_version_check = 0` is VimTeX's own documented escape hatch
			-- (:h vimtex_version_check) — it loads anyway, at the cost of upstream
			-- ignoring bug reports from the older version. Safe here: the gap is one
			-- patch release (image 0.12.3 vs required 0.12.4). Keep this in place;
			-- it's a no-op once the image catches up, and it avoids the .tex buffer
			-- breaking every time VimTeX bumps its floor ahead of the pinned nvim.
			vim.g.vimtex_version_check = 0

			-- general viewer → bookokrat-forward <line> <col> <tex> <pdf>.
			vim.g.vimtex_view_method = "general"
			vim.g.vimtex_view_general_viewer = "bookokrat-forward"
			vim.g.vimtex_view_general_options = "@line @col @tex @pdf"

			-- Silence VimTeX log messages that fire on plugin reload (e.g. after
			-- `:Lazy update` / LazyVim's auto-update, which re-sources plugins over
			-- any open .tex buffer). g:vimtex_log_ignore is a list of Vim regexes;
			-- any VimTeX message matching one is still recorded in :VimtexLog but is
			-- NOT echoed. This is the surgical mute — real compile errors
			-- ("Compilation stopped!" etc.) still show. The Treesitter entry below
			-- covers the "Syntax highlighting is controlled by Treesitter!" warning
			-- that VimTeX emits when it reloads over a buffer whose highlighting
			-- LazyVim hands to treesitter. If a DIFFERENT message keeps popping up,
			-- open :VimtexLog to copy its exact wording and add it as another
			-- pattern here (substrings work; it's a non-anchored Vim regex match).
			--
			-- (Blunt alternative, if ever wanted: `vim.g.vimtex_log_verbose = 0`
			-- silences every VimTeX message — but that also hides genuine errors.)
			vim.g.vimtex_log_ignore = {
				"Syntax highlighting is controlled by Treesitter",
			}
		end,
	},
}
