local plugin = {}

plugin.events_get_focus = { "FocusGained", "CmdlineLeave" }

-- nvim_create_autocmd shortcut
local autocmd = vim.api.nvim_create_autocmd

local function get_current_layout()
	local process = io.popen("qdbus org.kde.keyboard /Layouts org.kde.KeyboardLayouts.getLayout")
	if not (process == nil) then
		CurrentKeyboardLayout = process:read("*all")
		process:close()
	end
	return tonumber(CurrentKeyboardLayout)
end

local function set_layout(layout)
	os.execute("qdbus org.kde.keyboard /Layouts org.kde.KeyboardLayouts.setLayout " .. layout .. " > /dev/null 2>&1")
end

local saved_layout = get_current_layout()

function plugin.setup(opts)
	opts = opts or {}
	if opts.events_get_focus then
		plugin.events_get_focus = opts.events_get_focus
	end

	-- Leaving insert mode: change to english
	autocmd("InsertLeave", {
		pattern = "*",
		callback = function()
			vim.schedule(function()
				saved_layout = get_current_layout()
				set_layout(0)
			end)
		end,
	})

	-- Gets focus and in insert/visual mode: change to english
	autocmd(plugin.events_get_focus, {
		pattern = "*",
		callback = function()
			vim.schedule(function()
				saved_layout = get_current_layout()
				local current_mode = vim.api.nvim_get_mode().mode
				if
					current_mode == "n"
					or current_mode == "no"
					or current_mode == "v"
					or current_mode == "V"
					or current_mode == "^V"
				then
					set_layout(0)
				end
			end)
		end,
	})

	-- Loses focus/Enter insert mode: change to saved layout
	autocmd({ "FocusLost", "InsertEnter" }, {
		pattern = "*",
		callback = function()
			vim.schedule(function()
				set_layout(saved_layout)
			end)
		end,
	})
end

return plugin
