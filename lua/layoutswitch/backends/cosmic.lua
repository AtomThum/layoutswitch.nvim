-- COSMIC backend.
--
-- COSMIC has no D-Bus getter for the active layout. cosmic-comp instead
-- exposes the Wayland protocol `zcosmic_keyboard_layout_manager_v1`
-- (cosmic-protocols: unstable/cosmic-keyboard-layout-unstable-v1.xml):
--
--   manager.get_keyboard_layout(new_id layout, object wl_keyboard)
--   layout.set_group(uint group)   -- request
--   layout.group(uint group)       -- event: sent on creation and on every change
--
-- We talk to it directly through LuaJIT FFI on libwayland-client, keeping a
-- single connection open for the lifetime of Neovim.

local ffi = require("ffi")

local M = {}

ffi.cdef([[
struct wl_display;
struct wl_proxy;

struct wl_message {
  const char *name;
  const char *signature;
  const struct wl_interface **types;
};

struct wl_interface {
  const char *name;
  int version;
  int method_count;
  const struct wl_message *methods;
  int event_count;
  const struct wl_message *events;
};

struct wl_display *wl_display_connect(const char *name);
void wl_display_disconnect(struct wl_display *display);
int wl_display_get_fd(struct wl_display *display);
int wl_display_roundtrip(struct wl_display *display);
int wl_display_dispatch_pending(struct wl_display *display);
int wl_display_flush(struct wl_display *display);
int wl_display_prepare_read(struct wl_display *display);
int wl_display_read_events(struct wl_display *display);
void wl_display_cancel_read(struct wl_display *display);

struct wl_proxy *wl_proxy_marshal_flags(struct wl_proxy *proxy, uint32_t opcode,
                                        const struct wl_interface *interface,
                                        uint32_t version, uint32_t flags, ...);
int wl_proxy_add_listener(struct wl_proxy *proxy, void (**implementation)(void), void *data);
uint32_t wl_proxy_get_version(struct wl_proxy *proxy);
void wl_proxy_destroy(struct wl_proxy *proxy);

/* Declared as 1-element arrays so they decay to pointers. */
extern const struct wl_interface wl_registry_interface[1];
extern const struct wl_interface wl_seat_interface[1];
extern const struct wl_interface wl_keyboard_interface[1];

typedef void (*ls_registry_global_fn)(void *data, struct wl_proxy *registry,
                                      uint32_t name, const char *interface, uint32_t version);
typedef void (*ls_registry_global_remove_fn)(void *data, struct wl_proxy *registry, uint32_t name);
typedef void (*ls_layout_group_fn)(void *data, struct wl_proxy *layout, uint32_t group);
]])

local MARSHAL_FLAG_DESTROY = 1
local NULL = ffi.cast("void *", nil)

local MANAGER_NAME = "zcosmic_keyboard_layout_manager_v1"
local LAYOUT_NAME = "zcosmic_keyboard_layout_v1"

-- Everything libwayland holds a pointer to must stay referenced from Lua,
-- otherwise the GC frees it underneath the C library.
local keep = {}
local function pin(x)
  keep[#keep + 1] = x
  return x
end

local function u32(n)
  return ffi.cast("uint32_t", n)
end

local lib -- libwayland-client handle
local ifaces -- { manager = struct wl_interface*, layout = struct wl_interface* }

-- Translates the protocol XML into wl_interface structs.
local function build_interfaces()
  local null_types = pin(ffi.new("const struct wl_interface *[4]"))

  local layout_iface = pin(ffi.new("struct wl_interface[1]"))
  local manager_iface = pin(ffi.new("struct wl_interface[1]"))

  local function str(s)
    return pin(ffi.new("char[?]", #s + 1, s))
  end

  -- zcosmic_keyboard_layout_v1
  local layout_requests = pin(ffi.new("struct wl_message[2]"))
  layout_requests[0].name, layout_requests[0].signature, layout_requests[0].types = str("set_group"), str("u"), null_types
  layout_requests[1].name, layout_requests[1].signature, layout_requests[1].types = str("destroy"), str(""), null_types
  local layout_events = pin(ffi.new("struct wl_message[1]"))
  layout_events[0].name, layout_events[0].signature, layout_events[0].types = str("group"), str("u"), null_types

  layout_iface[0].name = str(LAYOUT_NAME)
  layout_iface[0].version = 1
  layout_iface[0].method_count = 2
  layout_iface[0].methods = layout_requests
  layout_iface[0].event_count = 1
  layout_iface[0].events = layout_events

  -- zcosmic_keyboard_layout_manager_v1
  local get_layout_types = pin(ffi.new("const struct wl_interface *[2]"))
  get_layout_types[0] = layout_iface
  get_layout_types[1] = lib.wl_keyboard_interface

  local manager_requests = pin(ffi.new("struct wl_message[2]"))
  manager_requests[0].name, manager_requests[0].signature, manager_requests[0].types =
    str("get_keyboard_layout"), str("no"), get_layout_types
  manager_requests[1].name, manager_requests[1].signature, manager_requests[1].types = str("destroy"), str(""), null_types

  manager_iface[0].name = str(MANAGER_NAME)
  manager_iface[0].version = 1
  manager_iface[0].method_count = 2
  manager_iface[0].methods = manager_requests
  manager_iface[0].event_count = 0
  manager_iface[0].events = nil

  return { manager = manager_iface, layout = layout_iface }
end

-- Connection state
local state = "uninit" -- "uninit" | "ok" | "dead"
local display, registry, seat, keyboard, manager, layout
local poll
local current_group
local globals = {} -- interface name -> { name = uint, version = uint }

local function as_proxy(p)
  return ffi.cast("struct wl_proxy *", p)
end

local function marshal(proxy, opcode, iface, flags, ...)
  return lib.wl_proxy_marshal_flags(proxy, opcode, iface, lib.wl_proxy_get_version(proxy), flags or 0, ...)
end

local function bind(iface_ptr, name, version)
  local g = globals[name]
  if not g then
    return nil
  end
  local v = math.min(g.version, version)
  -- wl_registry.bind (opcode 0), signature "usun": name, interface, version, new_id
  return lib.wl_proxy_marshal_flags(registry, 0, iface_ptr, v, 0, u32(g.name), iface_ptr[0].name, u32(v), NULL)
end

local function teardown()
  if poll then
    pcall(function()
      poll:stop()
      poll:close()
    end)
    poll = nil
  end
  if display ~= nil then
    if layout ~= nil then
      marshal(layout, 1, nil, MARSHAL_FLAG_DESTROY) -- zcosmic_keyboard_layout_v1.destroy
    end
    if manager ~= nil then
      marshal(manager, 1, nil, MARSHAL_FLAG_DESTROY) -- manager.destroy
    end
    for _, p in ipairs({ keyboard, seat, registry }) do
      if p ~= nil then
        lib.wl_proxy_destroy(p)
      end
    end
    lib.wl_display_flush(display)
    lib.wl_display_disconnect(display)
  end
  display, registry, seat, keyboard, manager, layout = nil, nil, nil, nil, nil, nil
end

local function die()
  teardown()
  state = "dead"
end

-- Reads whatever the compositor has sent and runs the callbacks.
local function drain()
  if state ~= "ok" then
    return
  end
  while lib.wl_display_prepare_read(display) ~= 0 do
    if lib.wl_display_dispatch_pending(display) < 0 then
      return die()
    end
  end
  lib.wl_display_flush(display)
  if lib.wl_display_read_events(display) < 0 then
    return die()
  end
  if lib.wl_display_dispatch_pending(display) < 0 then
    return die()
  end
end

local function roundtrip()
  if lib.wl_display_roundtrip(display) < 0 then
    die()
    return false
  end
  return true
end

local function init()
  lib = ffi.load("wayland-client.so.0")
  ifaces = build_interfaces()

  display = lib.wl_display_connect(nil)
  if display == nil then
    error("cannot connect to the Wayland display", 0)
  end
  local display_proxy = as_proxy(display)
  state = "ok"

  -- wl_display.get_registry (opcode 1)
  registry = marshal(display_proxy, 1, lib.wl_registry_interface, 0, NULL)

  local on_global = pin(ffi.cast("ls_registry_global_fn", function(_, _, name, iface, version)
    globals[ffi.string(iface)] = { name = name, version = version }
  end))
  local on_global_remove = pin(ffi.cast("ls_registry_global_remove_fn", function() end))
  local registry_listener = pin(ffi.new("void *[2]"))
  registry_listener[0] = ffi.cast("void *", on_global)
  registry_listener[1] = ffi.cast("void *", on_global_remove)
  lib.wl_proxy_add_listener(registry, ffi.cast("void (**)(void)", registry_listener), nil)

  if not roundtrip() then
    error("Wayland roundtrip failed", 0)
  end

  if not globals[MANAGER_NAME] then
    error(MANAGER_NAME .. " not advertised (old cosmic-comp, or sandboxed client)", 0)
  end

  seat = bind(lib.wl_seat_interface, "wl_seat", 1)
  manager = bind(ifaces.manager, MANAGER_NAME, 1)
  if seat == nil or manager == nil then
    error("failed to bind wl_seat / " .. MANAGER_NAME, 0)
  end

  -- wl_seat.get_keyboard (opcode 1). No listener: libwayland discards its
  -- events (and closes the keymap fd).
  keyboard = marshal(seat, 1, lib.wl_keyboard_interface, 0, NULL)
  -- manager.get_keyboard_layout (opcode 0), signature "no"
  layout = marshal(manager, 0, ifaces.layout, 0, NULL, keyboard)

  local on_group = pin(ffi.cast("ls_layout_group_fn", function(_, _, group)
    current_group = tonumber(group)
  end))
  local layout_listener = pin(ffi.new("void *[1]"))
  layout_listener[0] = ffi.cast("void *", on_group)
  lib.wl_proxy_add_listener(layout, ffi.cast("void (**)(void)", layout_listener), nil)

  if not roundtrip() then
    error("Wayland roundtrip failed", 0)
  end

  -- Pick up layout changes made elsewhere (e.g. the COSMIC shortcut) as they happen.
  poll = vim.uv.new_poll(lib.wl_display_get_fd(display))
  poll:start("r", function(err)
    if err then
      return die()
    end
    drain()
  end)

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("layoutswitch_cosmic", { clear = true }),
    callback = teardown,
  })
end

-- C callbacks into Lua must not be triggered from JIT-compiled code.
jit.off(drain, true)
jit.off(roundtrip, true)
jit.off(init, true)

local init_error

function M.available()
  if state == "uninit" then
    local ok, err = pcall(init)
    if not ok then
      init_error = err
      die()
    end
  end
  return state == "ok"
end

function M.error()
  return init_error
end

function M.get_layout()
  if not M.available() then
    return nil
  end
  roundtrip()
  return current_group
end

function M.set_layout(n)
  if not M.available() or n == nil then
    return
  end
  if n == current_group then
    return
  end
  -- zcosmic_keyboard_layout_v1.set_group (opcode 0)
  marshal(layout, 0, nil, 0, u32(n))
  if lib.wl_display_flush(display) < 0 then
    return die()
  end
  current_group = n
end

return M
