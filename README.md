# layoutswitch.nvim

An automatic keyboard layout switcher for Neovim. Supports **KDE Plasma** and **COSMIC** desktops on Linux.

This plugin is an adaptation ivanesmantovich's ``xkbswitch.nvim`` plugin for use with Fedora 42 and KDE. So, huge thanks to him for providing the basis of this code.

https://github.com/ivanesmantovich/xkbswitch.nvim

Note that this plugin doesn't use ``xkbswitch``. The backend is picked from ``$XDG_CURRENT_DESKTOP``:

- **KDE**: uses ``qdbus`` (``qdbus``, ``qdbus6`` or ``qdbus-qt6``) to talk to ``org.kde.keyboard``.
- **COSMIC**: talks directly to the compositor's ``zcosmic_keyboard_layout_manager_v1`` Wayland protocol through LuaJIT FFI (``libwayland-client.so.0``). Nothing to install or build. Requires a cosmic-comp that ships this protocol, a Wayland session, and a non-sandboxed Neovim (e.g. not a Flatpak).

## Instructions

Put the English layout as the first layout, the others can be anything.

When you exit insert mode, the plugin saves your current layout before switching to English. When you enter insert mode again, the saved layout will be automatically switched back.

Using ``lazy`` package manager,
```lua
  {
    "AtomThum/layoutswitch.nvim",
    config = function()
      require("layoutswitch").setup()
    end,
  },
```
Using ``vim.pack``
```lua
vim.pack.add("https://github.com/AtomThum/layoutswitch.nvim")
require("layoutswitch").setup()
```


## Options

```lua
require("layoutswitch").setup({
  -- Events after which the layout is reset to `default_layout` if in Normal/Visual mode.
  events_get_focus = { "FocusGained", "CmdlineLeave" },
  -- Layout index used outside Insert mode (0 = first configured layout).
  default_layout = 0,
  -- Force a backend ("kde" or "cosmic") instead of detecting it.
  backend = nil,
})
```
