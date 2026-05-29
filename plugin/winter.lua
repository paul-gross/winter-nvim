-- Guard against double-loading
if vim.g.loaded_winter then
  return
end
vim.g.loaded_winter = true

-- Require Neovim 0.9+ (minimum for snacks.nvim)
if vim.fn.has("nvim-0.9") == 0 then
  vim.notify(
    "winter.nvim requires Neovim >= 0.9. Please upgrade your Neovim installation.",
    vim.log.levels.ERROR
  )
  return
end

-- :Winter — open the workspace picker
vim.api.nvim_create_user_command("Winter", function()
  require("winter").open()
end, {
  desc = "Open the winter workspace picker",
})

-- :WinterRepos — alias for :Winter (future: may filter to repos only)
vim.api.nvim_create_user_command("WinterRepos", function()
  require("winter").open()
end, {
  desc = "Open the winter workspace picker (repos alias)",
})
