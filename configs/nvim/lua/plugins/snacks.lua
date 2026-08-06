-- Disable Snacks explorer's "send to trash" behavior.
--
-- Snacks.explorer.actions.trash() tries `trash` / `gio trash` / `kioclient`
-- before falling back to `vim.fn.delete(path, "rf")`. On HPC bind-mounts
-- like /work, `gio trash` aborts with:
--   "Trashing on system internal mounts is not supported"
-- and the delete fails outright (the fallback is only reached when no trash
-- binary is executable, not when one runs and errors).
--
-- Setting explorer.trash = false skips the trash commands entirely and uses
-- the plain delete fallback, which works on any filesystem.
--
-- Also routes the explorer's open action so PDFs open in bookokrat (terminal
-- reader, tmux split) instead of the default opener; non-PDFs fall through to
-- vim.ui.open (yazi/snacks preview images in-terminal; see pdf_open.lua).
--
-- Show hidden (dotfiles) and git-ignored files in the explorer by default
-- (`hidden`/`ignored`). On the container we work in dotfile- and .gitignore-
-- heavy trees and want them visible without toggling each session; the default
-- `H` / `I` keymaps still flip them off when desired.
-- Dashboard header art, stored as a LIST OF LINES and padded to a common display
-- width at runtime.
--
-- snacks centers each header line INDEPENDENTLY, so lines of unequal width sit
-- staggered instead of reading as one block. The previous ANSI Shadow art broke
-- exactly that way: the figlet "E" carries trailing spaces on two of its six rows,
-- something stripped them, and the rows then measured 74/74/72/72/74/75 — the two
-- short ones visibly offset. Padding here means no whitespace-trimming editor or
-- formatter can reintroduce that; the art is stored ragged on purpose.
--
-- strdisplaywidth, not #, because the art is multi-byte.
local function padded(lines)
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line .. string.rep(" ", width - vim.fn.strdisplaywidth(line))
  end
  return table.concat(out, "\n")
end

return {
  {
    "folke/snacks.nvim",
    opts = {
      -- Match the local LazyVim dashboard (same keymaps/sections), but stack a
      -- CIRCE wordmark under the logo so it's obvious at a glance that this
      -- session is the CIRCE container, not the local Mac. (Previously the whole
      -- header spelled "NVIM-CIRCE" in ANSI Shadow figlet.)
      --
      -- The logo is the community Neovim wordmark from the alpha-nvim ecosystem —
      -- the one typecraft uses in cpow/neovim-for-newbs (lua/plugins/alpha.lua).
      -- Only the art is borrowed; this stays on snacks, no alpha-nvim involved.
      -- It renders more steadily than the old ANSI Shadow art because it is
      -- essentially ONE glyph, U+2588 FULL BLOCK, plus four Powerline slants
      -- (U+E0B8/BA/BC/BE) for the bevelled terminals — whereas ANSI Shadow mixes
      -- Block Elements with Box Drawing (═║╔╗╚╝), and a font lacking either set
      -- pulls the missing half from a fallback face with different metrics, which
      -- is what made the seams shimmer.
      --
      -- CIRCE below it is hand-drawn to match: same 5-row cap height, same solid
      -- block texture, stem thickness 4 (the wordmark's is 5) so it reads as the
      -- same typeface a size down. Pure U+2588, no Powerline glyphs needed.
      -- The Powerline slants require a Nerd Font, which the container has.
      dashboard = {
        preset = {
          pick = function(cmd, opts)
            return LazyVim.pick(cmd, opts)()
          end,
          header = padded({
            "                                             ",
            "      ████ ██████           █████      ██",
            "     ███████████             █████ ",
            "     █████████ ███████████████████ ███   ███████████",
            "    █████████  ███    █████████████ █████ ██████████████",
            "   █████████ ██████████ █████████ █████ █████ ████ █████",
            " ███████████ ███    ███ █████████ █████ █████ ████ █████",
            "██████  █████████████████████ ████ █████ █████ ████ ██████",
            "",
            "        ███████████ ████ ███████████   ███████████ ████████████",
            "       ████         ████ ████    ████ ████         ████",
            "       ████         ████ ███████████  ████         ████████",
            "       ████         ████ ████    ████ ████         ████",
            "        ███████████ ████ ████    ████  ███████████ ████████████",
          }),
          keys = {
            { icon = " ", key = "f", desc = "Find File", action = ":lua Snacks.dashboard.pick('files')" },
            { icon = " ", key = "n", desc = "New File", action = ":ene | startinsert" },
            { icon = " ", key = "g", desc = "Find Text", action = ":lua Snacks.dashboard.pick('live_grep')" },
            { icon = " ", key = "r", desc = "Recent Files", action = ":lua Snacks.dashboard.pick('oldfiles')" },
            {
              icon = " ",
              key = "c",
              desc = "Config",
              action = ":lua Snacks.dashboard.pick('files', {cwd = vim.fn.stdpath('config')})",
            },
            { icon = " ", key = "s", desc = "Restore Session", section = "session" },
            { icon = " ", key = "x", desc = "Lazy Extras", action = ":LazyExtras" },
            { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy" },
            { icon = " ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
        -- snacks.nvim's own "compact_files" example layout.
        sections = {
          { section = "header" },
          { icon = " ", title = "Keymaps", section = "keys", indent = 2, padding = 1 },
          { icon = " ", title = "Recent Files", section = "recent_files", indent = 2, padding = 1 },
          { icon = " ", title = "Projects", section = "projects", indent = 2, padding = 1 },
          { section = "startup" },
        },
      },
      explorer = {
        trash = false,
      },
      picker = {
        sources = {
          explorer = {
            hidden = true,
            ignored = true,
            actions = {
              explorer_open = function(_, item)
                if not (item and item.file) then
                  return
                end
                if item.file:match("%.pdf$") then
                  -- nvim 0.12 strips TERM/TMUX/NVIM from job children (even
                  -- explicit env{} overrides), so bookokrat-split rediscovers
                  -- tmux itself and takes the editor socket as BK_NVIM — a
                  -- name nvim leaves alone.
                  vim.system({ "bookokrat-split", item.file }, { env = { BK_NVIM = vim.v.servername } })
                else
                  vim.ui.open(item.file)
                end
              end,
            },
          },
        },
      },
    },
  },
}
