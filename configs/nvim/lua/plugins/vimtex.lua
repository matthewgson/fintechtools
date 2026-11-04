-- vimtex.lua — LazyVim drop-in plugin spec, synced to CIRCE by sync_configs.sh
-- into ~/.config/nvim/lua/plugins/.  Augments the LazyVim `lang.tex` extra
-- (which installs lervag/vimtex) with this container's HPC / SSH viewer wiring.
--
-- VIEWER: farleaf (terminal PDF reader, the user's own).  farleaf is installed
-- INSIDE the container (Dockerfile Stage 5f) and draws the PDF inline via the
-- kitty graphics protocol, which ghostty renders straight over SSH and inside
-- herdr — no X11/XQuartz, no PDF copy shipped to the Mac.
--   * forward search  <localleader>lv  → farleaf-forward asks `synctex view`
--     (TinyTeX's synctex, Dockerfile Stage 5d) for the line's page and height
--     and opens the PDF there in a herdr split, or types `:PAGE:Y` into the
--     farleaf already showing it.
--   * inverse search  Ctrl-click (or `gd`) in farleaf → farleaf runs
--     $FARLEAF_SYNCTEX_EDITOR (set in .zshrc, and by farleaf-split), a helper
--     `nvim --headless -c "VimtexInverseSearch {line} {file}"`; VimTeX finds
--     the nvim that has the project open and goes to the line, and that nvim
--     then focuses its own herdr pane (the autocmd below, herdr-focus-pane).
--     Right-click is herdr's pane menu, hence Ctrl-click.
-- The farleaf-forward/-split and herdr-focus-pane helpers ship to
-- ~/.local/bin (on PATH inside the container) via sync_configs.sh.
--
-- This replaces bookokrat (until 2026-10-29), the sioyek-over-X11 viewer
-- before it, and the even older `mac-open` viewer, which shipped a *copy* of
-- the PDF to the Mac and therefore lost synctex.  `pdf_open.lua` routes other
-- PDF open callsites to farleaf.
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

			-- general viewer → farleaf-forward <line> <col> <tex> <pdf>.
			vim.g.vimtex_view_method = "general"
			vim.g.vimtex_view_general_viewer = "farleaf-forward"
			vim.g.vimtex_view_general_options = "@line @col @tex @pdf"

			-- After an inverse search the focus is still on farleaf's pane (the
			-- click was there): bring this nvim's own herdr pane forward. Same as
			-- the Mac's vimtex.lua, which this file replaces on CIRCE.
			vim.api.nvim_create_autocmd("User", {
				group = vim.api.nvim_create_augroup("FarleafInverseSearch", { clear = true }),
				pattern = "VimtexEventViewReverse",
				callback = function()
					local pane = vim.env.HERDR_PANE_ID
					if vim.env.HERDR_ENV == "1" and pane and vim.fn.executable("herdr-focus-pane") == 1 then
						vim.system({ "herdr-focus-pane", pane })
					end
				end,
			})

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
