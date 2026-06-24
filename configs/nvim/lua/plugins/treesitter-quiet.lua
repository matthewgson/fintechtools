-- Container-only: silence nvim-treesitter (main branch)'s "N/N installed"
-- notification that fires on every launch. The nvim plugin data lives on
-- node-local /tmp (the startup-speed patch), so the parsers don't persist and
-- the main branch re-checks/installs each session. Cosmetic — syntax
-- highlighting is unaffected. Lives in the repo (synced to the container only);
-- the Mac's parsers persist, so it never sees the message.
return {
  "nvim-treesitter/nvim-treesitter",
  init = function()
    -- Wrap vim.notify after the UI/notifier is up (snacks owns vim.notify), and
    -- drop only the treesitter "<n>/<n> installed" line.
    vim.api.nvim_create_autocmd("User", {
      pattern = "VeryLazy",
      once = true,
      callback = function()
        local orig = vim.notify
        vim.notify = function(msg, level, opts)
          if type(msg) == "string" and msg:match("%d+%s*/%s*%d+") and msg:lower():match("install") then
            return
          end
          return orig(msg, level, opts)
        end
      end,
    })
  end,
}
