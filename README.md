# layoutswitch.nvim

An automatic keyboard layout switcher for Neovim. Made for Fedora 42 on KDE only.

This plugin is an adaptation ivanesmantovich's ``xkbswitch.nvim`` plugin for use with Fedora 42 and KDE. So, huge thanks to him for providing the basis of this code.

[Context: "https://github.com/ivanesmantovich/xkbswitch.nvim"]

Note that this plugin doesn't use ``xkbswitch``. It uses ``qdbus`` instead.

## Instructions

Put the English layout as the first layout, the others can be anything.

When you exit insert mode, the plugin saves your current layout before switching to English. When you enter insert mode again, the saved layout will be automatically switched back.
