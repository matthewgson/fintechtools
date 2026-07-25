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
return {
  {
    "folke/snacks.nvim",
    opts = {
      -- Match the local LazyVim dashboard (same keymaps/sections), but render
      -- the header as "NVIM-CIRCE" instead of "NEOVIM" so it's obvious at a
      -- glance that this session is the CIRCE container, not the local Mac.
      -- ASCII art is the ANSI Shadow figlet font (same font as local NEOVIM).
      dashboard = {
        preset = {
          pick = function(cmd, opts)
            return LazyVim.pick(cmd, opts)()
          end,
          header = [[
███╗   ██╗██╗   ██╗██╗███╗   ███╗       ██████╗██╗██████╗  ██████╗███████╗
████╗  ██║██║   ██║██║████╗ ████║      ██╔════╝██║██╔══██╗██╔════╝██╔════╝
██╔██╗ ██║██║   ██║██║██╔████╔██║█████╗██║     ██║██████╔╝██║     █████╗
██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║╚════╝██║     ██║██╔══██╗██║     ██╔══╝
██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║      ╚██████╗██║██║  ██║╚██████╗███████╗
╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝       ╚═════╝╚═╝╚═╝  ╚═╝ ╚═════╝╚══════╝]],
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
