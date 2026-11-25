-- KDE backend: KWin exposes the active layout over D-Bus via qdbus.

local M = {}

local qdbus

local function find_qdbus()
  for _, exe in ipairs({ "qdbus", "qdbus6", "qdbus-qt6" }) do
    if vim.fn.executable(exe) == 1 then
      return exe
    end
  end
end

function M.available()
  qdbus = qdbus or find_qdbus()
  return qdbus ~= nil
end

function M.error()
  return "qdbus not found in $PATH"
end

function M.get_layout()
  local out = vim.fn.system({ qdbus, "org.kde.keyboard", "/Layouts", "org.kde.KeyboardLayouts.getLayout" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return tonumber(out)
end

function M.set_layout(n)
  if n == nil then
    return
  end
  vim.fn.system({ qdbus, "org.kde.keyboard", "/Layouts", "org.kde.KeyboardLayouts.setLayout", tostring(n) })
end

return M
