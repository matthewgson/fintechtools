-- r.lua — LazyVim drop-in plugin spec, synced to CIRCE by sync_configs.sh into
-- ~/.config/nvim/lua/plugins/.  Container-only override of the LazyVim `lang.r`
-- extra's R language server wiring.
--
-- PROBLEM: LazyVim's `lang.r` extra registers `r_language_server`, which by
-- default LazyVim provisions through Mason (the `r-languageserver` package).
-- In this container Mason tries to `install.packages("languageserver")` into a
-- per-user Mason tree on the slow HPC filesystem — it routinely fails to find
-- or finish installing it, so the R LSP never comes up.
--
-- FIX: the `languageserver` R package is baked into the system R library at
-- image-build time as a precompiled Posit PPM binary (Dockerfile Stage 5b-2).
-- Setting `mason = false` here tells LazyVim to SKIP Mason for this server and
-- start it directly from the `R` on $PATH — nvim-lspconfig's default
-- r_language_server cmd is `R --no-echo --no-save -e languageserver::run()`,
-- which loads that system copy. No per-user install, nothing to compile.
--
-- `root_markers` is left to replstudio.lua, which now registers the server in
-- place of the lang.r extra (DESCRIPTION / NAMESPACE / .Rbuildignore); LazyVim
-- deep-merges these server opts, so we only add the `mason = false` key
-- without clobbering the rest.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        r_language_server = {
          mason = false,
        },
      },
    },
  },
}
