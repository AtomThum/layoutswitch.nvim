local plugin = {}

plugin.config = {
  -- Events after which the layout is reset to `default_layout` if in Normal/Visual mode.
  events_get_focus = { "FocusGained", "CmdlineLeave" },
  -- Layout index used outside Insert mode (0 = the first configured layout).
  default_layout = 0,
  -- Force a backend ("kde" or "cosmic"); nil = detect from the desktop session.
  backend = nil,
}

local function detect_backend()
  local desktops = (vim.env.XDG_CURRENT_DESKTOP or "") .. ":" .. (vim.env.XDG_SESSION_DESKTOP or "")
  for desktop in desktops:gmatch("[^:]+") do
    desktop = desktop:upper()
    if desktop == "KDE" then
      return "kde"
    elseif desktop == "COSMIC" then
      return "cosmic"
    end
  end
end

local function warn(msg)
  vim.notify("layoutswitch: " .. msg, vim.log.levels.WARN)
end

local function is_normal_or_visual(mode)
  local m = mode:sub(1, 1)
  return m == "n" or m == "v" or m == "V" or m == "\22"
end

function plugin.setup(opts)
  local config = vim.tbl_extend("force", plugin.config, opts or {})
  plugin.config = config

  local name = config.backend or detect_backend()
  if not name then
    return warn("unsupported desktop (supported: KDE, COSMIC)")
  end
  local ok, backend = pcall(require, "layoutswitch.backends." .. name)
  if not ok then
    return warn("unknown backend '" .. name .. "'")
  end
  if not backend.available() then
    return warn(name .. " backend unavailable: " .. tostring(backend.error()))
  end

  local default = config.default_layout
  local saved_layout = backend.get_layout()

  local group = vim.api.nvim_create_augroup("layoutswitch", { clear = true })
  local autocmd = vim.api.nvim_create_autocmd

  -- Leaving insert mode: remember layout, switch to default
  autocmd("InsertLeave", {
    group = group,
    callback = function()
      vim.schedule(function()
        saved_layout = backend.get_layout()
        backend.set_layout(default)
      end)
    end,
  })

  -- Gaining focus in normal/visual mode: remember layout, switch to default
  autocmd(config.events_get_focus, {
    group = group,
    callback = function()
      vim.schedule(function()
        saved_layout = backend.get_layout()
        if is_normal_or_visual(vim.api.nvim_get_mode().mode) then
          backend.set_layout(default)
        end
      end)
    end,
  })

  -- Losing focus / entering insert mode: restore saved layout
  autocmd({ "FocusLost", "InsertEnter" }, {
    group = group,
    callback = function()
      vim.schedule(function()
        backend.set_layout(saved_layout)
      end)
    end,
  })
end

return plugin
