-- these are necessary because the mobdebug module recklessly calls
-- print and os.exit(!)
local _G_print = _G.print
_G.print = function() end
local _os_exit = os.exit
os.exit = function() coroutine.yield() end
local mdb = require "mobdebug"
local socket = require "socket"
local ui = require "ui"

local port = 8172 -- default

local client
local basedir = "."
local basefile = ""

local sources = {}
local current_src = {}
local current_file = ""
local current_line = 0
local selected_line
local select_cmd
local cmd_output = {}
local pinned_evals = {}
local display_pinned = true

---------- misc helpers ------------------------------------------------

local function output(...)
	cmd_output[#cmd_output+1] = table.concat({...}, " ")
end

local function output_error(...)
	output("Error:", ...)
end

local function output_debug(...)
	output("DBG:", ...)
end

-- opts: string of single char options, char followed by ':' means opt
-- needs a value
-- arg: table of arguments
function get_opts(opts, arg)
	local i = 1
	local opt, val
	local optt = {}
	local res = {}
	
	while i <= #opts do
		local ch = string.sub(opts, i, i)
		if string.sub(opts, i+1, i+1) == ':' then
			optt[ch] = true
			i = i + 2
		else
			optt[ch] = false
			i = i + 1
		end
	end
	
	i = 1
	while arg[i] do
		if string.sub(arg[i], 1, 1) == '-' then
			opt = string.sub(arg[i], 2, 2)
			if optt[opt] then
				if #arg[i] > 2 then
					val = string.sub(arg[i], 3)
					i = i + 1
				else
					val = arg[i+1]
					i = i + 2
				end
				if val == nil then
					return nil, "option -"..opt.." needs an argument"
				end
			elseif optt[opt] == false then
				if #arg[i] == 2 then
					val = true
					i = i + 1
				else
					return nil, "option -"..opt.." is a flag"
				end
			else
				return nil, "unknown option -"..opt
			end
			res[opt] = val
		else
			res[#res+1] = arg[i]
			i = i + 1
		end
	end
	
	return res
end

local function expand_tabs(txt, tw)
	tw = tw or 4
	local tbl = {}
	local pos = 1
	local w = 0
	local s, e = string.find(txt, "^[^\t]*\t", 1)
	while s do
		tbl[#tbl+1] = string.sub(txt, s, e-1)
		w = w + e - s
		tbl[#tbl+1] = string.rep(' ', tw - w % tw)
		w = w + tw - w % tw
		pos = e + 1
		s, e = string.find(txt, "^[^\t]*\t", e + 1)
	end
	tbl[#tbl+1] = string.sub(txt, pos)
	return table.concat(tbl)
end

local function get_file(file)
	if not sources[file] then
		local fn = file
		if string.sub(file, 1, 1) ~= '/' then
			fn = basedir .. '/' .. file
		end
		local f = io.open(file, "r")
		if not f then
			return nil, "could not load source file "..file
		end
		local txt = f:read("*a")
		f:close()
		txt = expand_tabs(txt, 4)
		local tt = {}
		string.gsub(txt, "([^\r\n]*)\r?\n", function(s) table.insert(tt, s) end)
		sources[file] = { txt = tt, lines = #tt, breakpts = {}, selected = 0 }
	end
	return sources[file]
end

local function set_current_file(file)
	local src, err = get_file(file)
	if not src then
		output_error(err)
		return
	end
	current_file = file
	current_src = src
end

---------- render display ----------------------------------------------

local function displaysource_renderrow(r, s, x, y, w, extra)
	local isbrk = extra.isbrk
	local linew = extra.linew

	local rs = string.format("%"..extra.linew.."d", r)
	ui.drawfield(x, y, rs, linew)

	if isbrk[r] then
		ui.setcell(x + linew, y, '*', ui.color.RED, ui.color.BLACK)
	end
	if extra.cur == r then
		ui.setcell(x + linew + 1, y, '-', ui.color.CYAN, ui.color.BLACK)
		ui.setcell(x + linew + 2, y, '>', ui.color.CYAN, ui.color.BLACK)
	end

	local fg, bg = ui.attributes()
	
	if extra.sel == r then
		ui.attributes(ui.getconfig('sel_fg'), ui.getconfig('sel_bg'))
	end

	return ui.drawfield(x + linew + 3, y, tostring(s), w - linew - 3)
end

function displaysource(source, x, y, w, h)
	local extra = {
		isbrk = source.breakpts,
		cur = current_line,
		sel = selected_line,
		linew = math.ceil(math.log10 and math.log10(source.lines) or math.log(source.lines, 10))
	}
	local first = (selected_line and selected_line or current_line) - math.floor(h/2)

	if first < 1 then
		first = 1
	elseif first + h > #source.txt then
		first = #source.txt - h + 2
	end
	ui.drawlist(source.txt, first, x, y, w, h, displaysource_renderrow, extra)
end

function displaypinned_renderrow(r, s, x, y, w, extra)
	local w1 = math.floor((w - 3) / 2)
	local w2 = w - w1
	if s then
		ui.drawfield(x, y, string.format("%2d:", r), 3)
		ui.drawfield(x + 3, y, s[1], w1 - 1)
		ui.setcell(x + 3 + w1 - 1, y, '=')
		ui.drawfield(x + 3 + w1, y, s[2], w2)
	end
end

function displaypinned(pinned, x, y, w, h)
	local extra
	local t = {}
	if h > 99 then h = 99 end
	while #pinned_evals > h do
		table.remove(pinned_evals, 1)
	end
	for i = 1, h do
		local expr = pinned_evals[i]
		if expr then
			local res, _, err = mdb.handle("eval " .. expr, client)
			if not err then
				t[i] = { expr, tostring(res) }
			else
				t[i] = { expr, "Error: "..err }
			end
		end
	end
	ui.rect(x, y, w, h)
	ui.drawlist(t, 1, x, y, w, h, displaypinned_renderrow, extra)
end

function displaycommands(cmds, x, y, w, h)
	local nco = #cmds
	local first = h > nco and 1 or nco - h + 1
	local y = y + (nco >= h and 1 or h - nco + 1)
	ui.drawtext(cmds, first, 1, y, w, h)
end

local function display()
	local w, h = ui.size()
	local th = h - 1
	local srch = math.floor(th / 3 * 2)
	local cmdh = th - srch
	local srcw = math.floor(w * 3 / 4)
	local pinw = w - srcw
	srch = srch - 1

	if (#pinned_evals == 0) or not display_pinned then
		srcw = w
		pinw = 0
	end
	
	ui.clear(ui.color.WHITE, ui.color.BLACK)
	ui.drawstatus({"Skript: "..(basefile or ""), "Dir: "..(basedir or ""), "press h for help"}, 1, ' | ')

	-- source view
	if select_cmd then
		selected_line = selected_line or current_line
		if select_cmd == ui.key.ARROW_UP then
			selected_line = selected_line - 1
		elseif select_cmd == ui.key.ARROW_DOWN then
			selected_line = selected_line + 1
		elseif select_cmd == ui.key.PGUP then
			selected_line = selected_line - srch
		elseif select_cmd == ui.key.PGDN then
			selected_line = selected_line + srch
		elseif select_cmd == ui.key.HOME then
			selected_line = 1
		elseif select_cmd == ui.key.END then
			selected_line = current_src.lines
		end
		select_cmd = nil
	end

	if selected_line then
		if selected_line < 1 then
			selected_line = 1
		elseif selected_line > current_src.lines then
			selected_line = current_src.lines
		end
	end
		
	ui.attributes(ui.color.WHITE, ui.color.BLACK)
	displaysource(current_src, 1, 2, srcw, srch-1)
	ui.drawstatus({"File: "..current_file, "Line: "..current_line.."/"..current_src.lines, #pinned_evals > 0 and "pinned: " .. #pinned_evals or ""}, srch + 1)
	
	-- variables view
	if pinw > 0 then
		ui.attributes(ui.color.WHITE, ui.color.BLUE)
		displaypinned(pinned_evals, srcw + 1, 2, pinw, srch-1)
	end

	-- commands view
	ui.attributes(ui.color.WHITE, ui.color.BLACK)
	displaycommands(cmd_output, 1, srch + 1, w, cmdh)
	
	-- input line
	ui.printat(1, h, string.rep(' ', w))
	ui.setcursor(1,h)
	
	-- more

	ui.present()
end

---------- starting up the debugger ------------------------------------

local function unquote(s)
	s = string.gsub(s, "^%s*(%S.+%S)%s*$", "%1")
	local ch = string.sub(s, 1, 1)
	if ch == "'" or ch == '"' then
		s = string.gsub(s, "^" .. ch .. "(.*)" .. ch .. "$", "%1")
	end
	return s
end

local function find_current_basedir()
	local pwd = unquote(mdb.handle("eval os.getenv('PWD')", client))
	local arg0 = unquote(mdb.handle("eval arg[0]", client))
	if pwd and arg0 then
		basedir = pwd
		basefile = string.match(arg0, "/([^/]+)$") or arg0
	end
end

local function startup()
	ui.attributes(ui.getconfig('fg'), ui.getconfig('bg'))

	local msg = "Waiting for connections on port "..port
	local x, y, w, h = ui.frame(#msg, 5, "debug.lua")
	ui.printat(x, y+1, msg, w)
	ui.present()
	
	local bw, bp, bo = math.floor(#msg/2), 1, 1
	local bx = x + math.floor((w - bw) / 2)
	
	local server = socket.bind('*', port)
	if not server then
		return nil, "could not open server socket."
	end
	server:settimeout(0.3)
	repeat
		ui.printat(bx, y+3, string.rep(' ', bw), bw)
		ui.setcell(bx + bp - 1, y+3, '=')
		if bp > 1 then ui.setcell(bx + bp - 2, y+3, '-') end
		if bp < bw then ui.setcell(bx + bp, y+3, '-') end
		bp = bp + bo
		if bp >= bw or bp <= 1 then bo = -bo end
		ui.present()
		client = server:accept()
		evt = ui.pollevent(0)
		if evt and (evt.key == ui.key.ESC or evt.char == 'q' or evt.char == 'Q') then return nil end
	until client ~= nil
	server:settimeout()

	find_current_basedir()
	return true
end

---------- debugger commands -------------------------------------------

local function dbg_help(cmdl)
	local em = ui.color.WHITE + ui.format.BOLD
	local t = {
		"commands without arguments are executed immediately,",
		"without the need to press Enter. Commands with",
		"arguments will present you with a command line to",
		"enter the whole command into. You can cancel this",
		"and all popups using the ESC key.",
		"",
		"Commands:",
		"=========",
		"b [file] line | set breakpoint",
		"db [file] line| delete breakpoint",
		"= expr        | evaluate expression",
		"! expr        | evaluate and pin expression",
		"d! [num]      | delete one or all pinned expressions",
		"n             | step over next statement",
		"s             | step into next statement",
		"r             | run program",
		"c num         | continue for num steps",
		"R             | restart debugging session",
		"B dir         | set basedir",
		"P             | toggle pinned expressions display",
		"S file        | show source file",
		"h             | help",
		"q             | quit",
		"[page] up/down| navigate source file",
		"left/right    | select current line",
		".             | reset view",
	}
	ui.text(t, "Help")
end

local function dbg_stack()
	local res, line, err = mdb.handle("stack", client)
	if res then
		local r = {}
		for k, v in ipairs(res) do
			r[k] = v[1]
		end
		res = r
	end
	return res, err
end

local function update_where()
		local s = dbg_stack()
		current_line = s[1][4]
		set_current_file(s[1][2])
		output(current_file, ":", current_line)
end

local function dbg_over(cmdl)
	local res, line, err = mdb.handle("over", client)
	update_where()
	return nil, err
end

local function dbg_step(cmdl)
	local res, line, err = mdb.handle("step", client)
	update_where()
	return nil, err
end

local function dbg_run(cmdl)
	local res, line, err = mdb.handle("run", client)
	update_where()
	return nil, err
end

local function dbg_reload(cmdl)
	local res, line, err = mdb.handle("reload", client)
	update_where()
	return nil, err
end

local function dbg_cont(cmdl)
	local num = string.match(cmdl, "^c%s*(%d+)%s*$")
	if not num then
		return nil, "command requires one numeric argument"
	end

	for i=1, num-1 do
		dbg_step()
	end
	local res, err = dbg_step()
	update_where()
	return res, err
end

local function dbg_eval(cmdl)
	local expr = string.match(cmdl, "^=%s*(.+)%s*$")
	if not expr then
		return nil, "command requires an expression as argument"
	end
	local res, line, err = mdb.handle("eval " .. expr, client)
	if not err and res == nil then res = "nil" end
	return res, err
end

local function dbg_pin_eval(cmdl)
	local expr = string.match(cmdl, "^!%s*(.+)%s*$")
	if not expr then
		return nil, "command requires an expression as argument"
	end
	table.insert(pinned_evals, expr)
	local res, line, err = mdb.handle("eval " .. expr, client)
	if not err and res == nil then res = "nil" end
	return res, err
end

local function dbg_delpin(cmdl)
	local pin = string.match(cmdl, "^d!%s*(%d*)%s*$")
	if not pin then
		return nil, "command requires none or one numeric argument"
	end
	if pin ~= '' then
		pin = tonumber(pin)
		if pin >= 1 and pin <= #pinned_evals then
			table.remove(pinned_evals, pin)
			return "deleted pinned expession #" .. tostring(pin)
		else
			return nil, "invalid pin number"
		end
	else
		pinned_evals = {}
		return "deleted all pinned expessions"
	end
end

local function dbg_setb(cmdl)
	local file, line = current_file, string.match(cmdl, "^b%s*(%d+)%s*$")
	local res, err
	if not line then
		local _, pos, ch = string.find(cmdl, "^b%s*(%S)")
		if ch == '"' or ch == "'" then
			file, line = string.match(cmdl, "^(.+[^\\])%"..ch.."%s+(%d+)%s*$", pos+1)
		else
			file, line = string.match(cmdl, "^b%s*(%S+)%s+(%d+)%s*$")
		end
		if file == '-' then file = current_file end
	end
	if file then
		res, err = get_file(file)
		if not res then file = nil end
	end
	if file and line then
		res, line, err = mdb.handle("setb " .. file .. " " .. line, client)
		if not err then
			res = "added breakpoint at " .. res .. " line " .. line
			get_file(file).breakpts[tonumber(line)] = true
		else
			res = nil
		end
	else
		err = "command requires file (optional) and line number as arguments"
	end
	return res, err
end

local function dbg_delb(cmdl)
	local file, line = current_file, string.match(cmdl, "^db%s*(%d+)%s*$")
	if not line then
		local _, pos, ch = string.find(cmdl, "^db%s*(%S)")
		if ch == '"' or ch == "'" then
			file, line = string.match(cmdl, "^(.+[^\\])%"..ch.."%s+(%d+)%s*$", pos+1)
		else
			file, line = string.match(cmdl, "^db%s*(%S+)%s+(%d+)%s*$")
		end
	end
	local res, line, err = mdb.handle("delb " .. file .. " " .. line, client)
	if not err then
		local r = "deleted breakpoint at "
		r = r .. (res == '-' and current_file or res)
		res = r .. " line " .. line
		get_file(file).breakpts[tonumber(line)] = nil
	else
		res = nil
	end
	return res, err
end

local function dbg_del(cmdl)
	local ch = string.sub(cmdl, 2, 2)
	if ch == "b" then
		return dbg_delb(cmdl)
	elseif ch == "!" then
		return dbg_delpin(cmdl)
	end
	return nil, "unknown del function: "..ch
end

local function dbg_set_basedir(cmdl)
	local res, err
	local _, pos, ch = string.find(cmdl, "^B%s*(%S)")
	if ch == '"' or ch == "'" then
		file = string.match(cmdl, "^(.+[^\\])%"..ch.."%s*$", pos+1)
	else
		file = string.match(cmdl, "^B%s*(%S+)%s*$")
	end
	if file then
		basedir = file
		res, _, err = mdb.handle("basedir " .. basedir, client)
		if not err then res = "basedir is now "..basedir end
	else
		err = "command requires directory as argument"
	end
	return res, err
end

local function dbg_toggle_pinned(cmdl)
	display_pinned = not display_pinned
	return (display_pinned and "" or "don't ") .. "display pinned evals"
end

local function dbg_showfile(cmdl)
	local file
	local _, pos, ch = string.find(cmdl, "^S%s*(%S)")
	if ch == '"' or ch == "'" then
		file = string.match(cmdl, "^(.+[^\\])%"..ch.."%s*$", pos+1)
	else
		file = string.match(cmdl, "^S%s*(%S+)%s*$")
	end
	local src, err = get_file(file)
	if not src then return nil, err end
	current_file = file
	current_src = src
end

local function dbg_return(cmdl)
	-- does nothing, the main loop does everything.
end

local dbg_imm = {
	['h'] = dbg_help,
	['s'] = dbg_step,
	['n'] = dbg_over,
	['r'] = dbg_run,
	['R'] = dbg_reload,
	['P'] = dbg_toggle_pinned,
	['.'] = dbg_return,
}

local dbg_cmdl = {
	['c'] = dbg_cont,
	['b'] = dbg_setb,
	['d'] = dbg_del,
	['='] = dbg_eval,
	['!'] = dbg_pin_eval,
	['B'] = dbg_set_basedir,
	['S'] = dbg_showfile,
}

local use_selection = {
	['b'] = function() return "b " .. tostring(selected_line) end,
	['d'] = function() if current_src.breakpts[selected_line] then return "db " .. tostring(selected_line) else return "d" end end,
}

---------- main --------------------------------------------------------

local main = coroutine.create(function()

	ui.outputmode(ui.color.COL256)
	local w, h = ui.size()

	local opts, err = get_opts("p:h?", arg)
	if not opts or opts.h or opts['?'] then
		local ret = err and err .. "\n" or ""
		return ret .. "usage: "..arg[0] .. " [-p port]"
	end
	if opts.p then
		port = tonumber(opts.p)
		if not port then error("argument to -p needs to be a port number") end
	end

	local ok, err = startup(port)
	if not ok then error(err) end

	local quit = false
	local result, err
	local first = 1

	update_where()

	repeat
		w, h = ui.size()
		display()
		evt = ui.pollevent()
		if evt and evt.char ~= "" then
			local ch = evt.char or ''
			if dbg_imm[ch] then
				output(ch)
				result,err = dbg_imm[ch]()
				selected_line = nil
			elseif dbg_cmdl[ch] then
				local prefill = ch
				if selected_line and use_selection[ch] then
					prefill = use_selection[ch]()
				end
				local cmdl = ui.input(1, h, w, prefill)
				if cmdl then
					output(cmdl)
					result, err = dbg_cmdl[ch](cmdl)
				end
				selected_line = nil
			elseif ch == "q" then
				selected_line = nil
				quit = ui.ask("Really quit?") == 1
			end
			
			if err then
				output_error(err)
			elseif result then
				output("->", result)
			end
					
			result, line, err = nil, nil, nil
		else
			local key = evt.key
			if key == ui.key.ARROW_UP or key == ui.key.ARROW_DOWN or
			   key == ui.key.ARROW_LEFT or key == ui.key.ARROW_RIGHT or
			   key == ui.key.PGUP or key == ui.key.PGDN or
			   key == ui.key.HOME or key == ui.key.END then
				select_cmd = key
			end
		end
	until quit
end)

local ok, err = coroutine.resume(main)
ui.shutdown()
client:close()

if not ok and err then
	_G_print("Error: "..tostring(err))
	_G_print(debug.traceback(main))
elseif err then
	_G_print(err)
else
	_G_print("Bye.")
end

