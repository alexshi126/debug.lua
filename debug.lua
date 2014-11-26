local _G_print = _G.print
_G.print = function() end
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
local cmd_output = {}
local pinned_evals = {}

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
		local f = io.open(file, "r")
		if not f then
			return nil, "could not load source file "..f
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
	if not sources[file] then
		local ok, err = get_file(file)
		if not ok then
			output_error(err)
			return
		end
	end
	current_file = file
	current_src = sources[file]
end

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
	
	if extra.selected == r then
		ui.attributes(ui.getconfig('sel_fg'), ui.getconfig('sel_bg'))
	end

	if type(s) == "string" then return ui.drawfield(x + linew + 3, y, s, w - linew - 3) end

	return nil
end

function displaysource(source, x, y, w, h)
	local extra = {
		isbrk = source.breakpts,
		cur = current_line,
		linew = math.ceil(math.log10 and math.log10(source.lines) or math.log(source.lines, 10))
	}
	local first = current_line - math.floor(h/2)
	if first < 1 then
		first = 1
	elseif first + h > #source.txt then
		first = #source.txt - h + 2
	end
	ui.drawlist(source.txt, first, x, y, w, h-1, displaysource_renderrow, extra)
end

local function display()
	local w, h = ui.size()
	local th = h - 1
	local srch = math.floor(th / 3 * 2)
	local cmdh = th - srch
	
	ui.clear(ui.color.WHITE, ui.color.BLACK)
	ui.drawstatus({"Skript: "..(basefile or ""), "Dir: "..(basedir or ""), "press h for help"}, 1, ' | ')
	
	-- source view
	ui.attributes(ui.color.WHITE, ui.color.BLACK)
	displaysource(current_src, 1, 2, w, srch)
	ui.drawstatus({"File: "..current_file, "Line: "..current_line, ""}, srch + 1)
	
	-- variables view
	
	-- commands view
	ui.attributes(ui.color.WHITE, ui.color.BLACK)
	local nco = #cmd_output
	local first = cmdh > nco and 1 or nco - cmdh + 2
	local y = srch + 1 + (nco >= cmdh and 1 or cmdh - nco)
	ui.drawtext(cmd_output, first, 1, y, w, cmdh-1)
	ui.printat(1, h, string.rep(' ', w))
	ui.setcursor(1,h)
	
	-- more

	ui.present()
end

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
	local a0d = string.match(arg0, "^(.*)/[^/]+$")
	if a0d == "" then a0d = "/" end
	if pwd and arg0 then
		if string.sub(arg0, 1, 1) == "/" then
			basedir = a0d
		elseif string.find(arg0, '/', 1, true) then
			basedir = pwd.."/"..a0d
		else
			basedir = pwd
		end
		basefile = string.match(arg0, "/([^/]+)$") or arg0
	end
end

local function startup()
	ui.attributes(ui.getconfig('fg'), ui.getconfig('bg'))

	local msg = "Run the program you wish to debug"
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

local function output(...)
	cmd_output[#cmd_output+1] = table.concat({...}, " ")
end

local function output_error(...)
	output("Error:", ...)
end
-- debugger commands

local function dbg_help(cmdl)
	local em = ui.color.WHITE + ui.format.BOLD
	local t = {
		"commands without arguments are executed immediately,",
		"without the need to press Enter. Commands with",
		"arguments will present you with a command line to",
		"enter the whole command into.",
		"",
		"Commands:",
		"=========",
		"b [file] line | set breakpoint",
		"db [file] line| delete breakpoint",
		"= expr        | evaluate expression",
		"! expr        | evaluate and pin expression",
		"d! num        | delete pinned expression",
		"n             | step over next statement",
		"s             | step into next statement",
		"r             | run program",
		"R             | reload program",
		"c num         | continue for num steps",
		"D dir         | set basedir",
		"h             | help",
		"q             | quit"
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
	table.insert(pinned_evals, 1, expr)
	local res, line, err = mdb.handle("eval " .. expr, client)
	return res, err
end

local function dbg_delpin(cmdl)
	local pin = string.match(cmdl, "^d!%s*(%d+)%s*$")
	if not pin then
		return nil, "command requires one numeric argument"
	end
	pin = tonumber(pin)
	if pin >= 1 and pin <= #pinned_evals then
		table.remove(pinned_evals, pin)
	else
		return nil, "invalid pin number"
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
	if file and line then
		res, line, err = mdb.handle("setb " .. file .. " " .. line, client)
		if not err then
			res = "added breakpoint at " .. res .. " line " .. line
			get_file(file).breakpts[line] = true
		else
			res = nil
		end
	else
		err = "command requires file (optional) and line number as arguments"
	end
	return res, err
end

local function dbg_delb(cmdl)
	local file, line = '-', string.match(cmdl, "^db%s*(%d+)%s*$")
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
		get_file(file).breakpts[line] = nil
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
	local err = nil
	local _, pos, ch = string.find(cmdl, "^B%s*(%S)")
	if ch == '"' or ch == "'" then
		file = string.match(cmdl, "^(.+[^\\])%"..ch.."%s*$", pos+1)
	else
		file = string.match(cmdl, "^B%s*(%S+)%s*$")
	end
	if file then
		basedir = file
	else
		err = "command requires directory as argument"
	end
	return nil, err
end

local dbg_imm = {
	['h'] = dbg_help,
	['s'] = dbg_step,
	['n'] = dbg_over,
	['r'] = dbg_run,
	['R'] = dbg_reload,
}

local dbg_cmdl = {
	['c'] = dbg_cont,
	['b'] = dbg_setb,
	['d'] = dbg_del,
	['='] = dbg_eval,
	['!'] = dbg_pin_eval,
	['D'] = dbg_set_basedir,
}

-- main

local main = coroutine.create(function()

	ui.outputmode(ui.color.COL256)
	local w, h = ui.size()

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
		if evt and evt.char then
			ch = string.lower(evt.char or '')
			if dbg_imm[ch] then
				output(ch)
				result,err = dbg_imm[ch]()
			elseif dbg_cmdl[ch] then
				local cmdl = ui.input(1, h, w, ch)
				if cmdl then
					output(cmdl)
					result, err = dbg_cmdl[ch](cmdl)
				end
			elseif ch == "q" then
				quit = ui.ask("Really quit?") == 1
			end
			
			if err then
				output_error(err)
			elseif result then
				output("->", result)
			end
					
			result, line, err = nil, nil, nil
		end
	until quit

	client:close()
	server:close()

end)

local ok, err = coroutine.resume(main)

ui.shutdown()
if not ok then
	_G_print("Error: "..tostring(err))
	-- debugging only:
	_G_print(debug.traceback(main))
end
_G_print("Bye.")
