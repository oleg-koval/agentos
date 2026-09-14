-- Linux overrides for the shared Neovim configuration's macOS-only mini.files actions.
vim.api.nvim_create_autocmd('User', {
  pattern = 'MiniFilesBufferCreate',
  group = vim.api.nvim_create_augroup('mini-files-linux-keymaps', { clear = true }),
  callback = function(args)
    local function entry_path()
      local entry = MiniFiles.get_fs_entry()
      return entry and entry.path or nil
    end

    local map = function(lhs, fn, desc)
      vim.keymap.set('n', lhs, fn, { buffer = args.data.buf_id, desc = desc })
    end

    map('O', function()
      local path = entry_path()
      if path then vim.system({ 'xdg-open', path }, { detach = true }) end
    end, 'Open in default application')

    map('<leader>i', function()
      local path = entry_path()
      if path then vim.system({ 'xdg-open', path }, { detach = true }) end
    end, 'Preview in default application')

    map('<leader>Y', function()
      local path = entry_path()
      if not path then return end
      vim.fn.setreg('+', path)
      vim.notify('Path copied: ' .. path)
    end, 'Copy path to clipboard')

    map('<leader>p', function()
      vim.notify('File clipboard paste is macOS-specific; use yazi to copy files.', vim.log.levels.WARN)
    end, 'Explain file paste limitation')
  end,
})
