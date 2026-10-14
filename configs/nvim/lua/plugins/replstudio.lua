-- replstudio.lua — container copy of the Mac's lua/plugins/replstudio.lua.
-- sync_configs.sh overlays configs/nvim/ onto the Mac's ~/.config/nvim, so this
-- file REPLACES the Mac one of the same name on CIRCE. Keep the two in step:
-- an option added on the Mac only does not reach the container.
--
-- One difference from the Mac spec, forced by where it runs: the Mac loads the
-- working tree via `dir = <Dropbox path>`, which does not exist on CIRCE. Here
-- lazy.nvim clones it from GitHub like any other plugin, so the container runs
-- what has been PUSHED, not local edits.
--
-- Its Python venv is NOT in the image: replstudio offers to create its default
-- one (~/.local/share/replstudio/venv, on $HOME) the first time a project has
-- no venv of its own, and anything else (polars, quantpolars, ...) goes in with
-- `:ReplStudio venv add`. Pure Python wheels are safe to install at runtime; it
-- is runtime-installed *executables* that F3 does not patch. ragg for R plots
-- lives in the user R library on $HOME the same way.
--
-- In the image: the duckdb CLI for the parquet viewer (Stage 8e-2) and R's
-- languageserver (Stage 5b-2; r.lua sets mason = false for it). quarto-render.nvim
-- needs no container copy: the Mac spec already pulls it from GitHub, and
-- Quarto is Stage 5c.
return {
  {
    "matthewgson/replstudio.nvim",
    ft = { "r", "python", "quarto" },
    cmd = "ReplStudio",
    event = "BufReadCmd *.parquet",
    opts = {},
  },
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "r", "rnoweb" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        r_language_server = {
          root_markers = { "DESCRIPTION", "NAMESPACE", ".Rbuildignore" },
        },
      },
    },
  },
}
