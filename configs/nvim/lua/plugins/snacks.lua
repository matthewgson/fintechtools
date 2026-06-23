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
return {
  {
    "folke/snacks.nvim",
    opts = {
      explorer = {
        trash = false,
      },
      picker = {
        sources = {
          explorer = {
            actions = {
              explorer_open = function(_, item)
                if not (item and item.file) then
                  return
                end
                if item.file:match("%.pdf$") then
                  vim.system({ "bookokrat-split", item.file })
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
