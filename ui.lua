local tfx = require "termfx"

local config
local function resetconfig()
	config = {
		fg = tfx.color.WHITE,
		bg = tfx.color.BLUE,

		sel_fg = tfx.color.BLACK,
		sel_bg = tfx.color.CYAN,

		ui_fg = tfx.color.CYAN,
		ui_bg = tfx.color.BLUE,

		elem_bg = tfx.color.WHITE,
		elem_fg = tfx.color.BLUE,
		
		sep = '|'
	}
end

local function getconfig(n)
	return config[n]
end

-- helper
-- augment for type that can recognize userdata with a named metatable
local _type = type
local type = function(v)
	local t = _type(v)
	if t == "userdata" or t == "table" then
		local mt = getmetatable(v)
		if mt then
			if mt.__type then
				if type(mt.__type) == "function" then
					return string.lower(mt.__type(t))
				else
					return string.lower(mt.__type)
				end
			elseif t == "userdata" then
				local reg = debug.getregistry()
				for k, v in pairs(reg) do
					if v == mt then
						return string.lower(k)
					end
				end
			end
		end
	end
	return t
end

-- api
-- draw a frame for an ui element
-- top left is x, y, dimensions are w, h, title is optional
-- may resize frame if it leaves the screen somewhere.
-- returns x, y, w, h of frame contents
local function drawframe(x, y, w, h, title)
	local tw, th = tfx.size()
	local pw = 0

	if title then
		title = tostring(title)
		pw = #title
		if w < #title then w = #title end
	end

	if x < 2 then x = 2 end
	if y < 2 then y = 2 end
	if x + w >= tw then w = tw - x end
	if y + h >= th then h = th - y end

	local ccell = tfx.newcell('+')
	local hcell = tfx.newcell('-')
	local vcell = tfx.newcell('|')
	
	for i = x, x+w do
		tfx.setcell(i, y-1, hcell)
		tfx.setcell(i, y+h, hcell)
	end
	for i = y, y+h do
		tfx.setcell(x-1, i, vcell)
		tfx.setcell(x+w, i, vcell)
	end
	tfx.setcell(x-1, y-1, ccell)
	tfx.setcell(x-1, y+h, ccell)
	tfx.setcell(x+w, y-1, ccell)
	tfx.setcell(x+w, y+h, ccell)
	
	tfx.rect(x, y, w, h, ' ')

	if title then
		if w < pw then pw = w end
		tfx.printat(x + (w - pw) / 2, y - 1, title, pw)
	end
	
	return x, y, w, h
end

-- helper
-- draw a frame of width w and height h, centered on the screen
-- title is optional
local function frame(w, h, title)
	local tw, th = tfx.size()
	if w + 2 > tw then w = tw - 2 end
	if h + 2 > th then h = th - 2 end
	local x = math.floor((tw - w) / 2)
	local y = math.floor((th - h) / 2)
	return drawframe(x, y, w, h, title)
end

-- helper
-- format a string to fit a certain width. Returns a table with the lines
local function format(msg, w)
	if not w then return { msg } end
	local _
	local last = #msg
	local pos, posn = 1, 0
	local ss, se = string.find(msg, "%s+", pos)
	local ps, pe, pc = string.find(msg, "%s*(%p)", pos)
	local words = {}
	while ss or ps do
		ps = ps or last + 1
		ss = ss or last + 1
		if ps <= ss then
			words[#words+1] = string.sub(msg, pos, ps-1) .. pc
			pos = pe + 1
		else
			words[#words+1] = string.sub(msg, pos, ss - 1)
			pos = se + 1
		end
		_, posn = string.find(msg, "^%s+", pos)
		if posn then
			pos = posn+1
		end
		ss, se = string.find(msg, "%s+", pos)
		ps, pe, pc = string.find(msg, "%s*(%p)", pos)
	end
	if pos <= last then words[#words+1] = string.sub(msg, pos) end

	local res, ln = {}, nil
	
	for i=1, #words do
		if ln then
			if #ln + 1 + #words[i] > w then
				res[#res+1] = ln
				ln = words[i]
				while #ln > w do
					res[#res+1] =  string.sub(ln, 1, w)
					ln = string.sub(ln, w+1)
				end
			else
				ln = ln .. " " .. words[i]
			end
		else
			ln = words[i]
			while #ln > w do
				res[#res+1] =  string.sub(ln, 1, w)
				ln = string.sub(ln, w+1)
			end
		end
	end
	if ln then res[#res+1] = ln end
	
	return res
end

-- helper
-- returns true if evt contains a keypress for what is considered an
-- escape key, one that closes the current window. This can be forced to
-- only be escape, or to also include enter.
-- return true if evt contains an escape key press, false if not.
local function is_escape_key(evt, onlyesc)
	if not evt then return false end
	if evt.key == tfx.key.ESC then
		return true
	end
	if not onlyesc and evt.key == tfx.key.ENTER then
		return true
	end
	return false
end

-- helper
-- draw a simple string s at pos x, y, width w, filling the rest between
-- #s and w with f or blanks
-- returns true
local function drawfield(x, y, s, w, f)
	f = f or ' '
	s = tostring(s)
	tfx.printat(x, y, s, w)
	if #s < w then
		tfx.printat(x + #s, y, string.rep(f, w - #s))
	end
	return true
end

-- api
-- draw a list of rows contained in tbl at position x, y, size w, h.
-- first is first line to show, may be modified. renderrow, if present,
-- is a function to render an individual row, which defaults to  a simple
-- function calling drawfield(). The functions signature is
-- renderrow(row, s, x, y, w, extra)
-- where row is the row number, s is the string, x, y is the position,
-- w is the width and extra is what was passed to drawlist as rr_extra

-- default renderrow function:
local function default_renderrow(row, s, x, y, w, extra)
	if s then
		drawfield(x, y, tostring(s), w)
	end
end

local function drawlist(tbl, first, x, y, w, h, renderrow, rr_extra)
	local fg, bg = tfx.attributes()
	local tw, th = tfx.size()
	local sx, sy
	local fo, bo, hl
	local ntbl = #tbl
	
	if ntbl == 0 then return end

	renderrow = renderrow or default_renderrow

	if first < 1 then
		first = 1
	end

	if ntbl >= h then
		w = w - 1
		sx = x + w
		sy = y
		if ntbl - first + 1 <= h then
			first = ntbl - h + 1
			if first < 1 then
				first = 1
				h = ntbl < h and ntbl or h
			end
		end
	end
	
	if w < 1 or h < 1 or x > tw or y > th or x + w < 1 or y + h < 1 then
		return false
	end
	
	-- contents
	first = first - 1
	for i=1, h do
		local s = tbl[first + i] 
		tfx.attributes(fg, bg)
		renderrow(first + i, s, x, y, w, rr_extra)
		y = y + 1
	end
	
	-- scrollbar
	if ntbl > h then
		local sh = math.floor(h * h / ntbl)
		local sf = math.floor(first * (h - sh) / (ntbl - h)) + sy
		if sf + sh > h then sf = h - sh + 1 end
		local sl = sf + sh
		for yy = sy, sy + h - 1 do
			if yy >= sf and yy <= sl then
				tfx.setcell(sx, yy, '#', config.elem_fg, config.elem_bg)
			else
				tfx.setcell(sx, yy, ' ', config.elem_fg, config.elem_bg)
			end
		end
	end
	
	return first + 1
end

----- drawtext -----

-- api
-- draw some text. The argument table contains strings
local function drawtext_renderrow(row, s, x, y, w, extra)
	if s then
		if extra.hr and row == extra.hr then
			tfx.attributes(config.sel_fg, config.sel_bg)
		end
		drawfield(x, y, s, w)
	end
end

local function drawtext(tbl, first, x, y, w, h, hr)
	local extra = { hr = hr }
	return drawlist(tbl, first, x, y, w, h, drawtext_renderrow, extra)
end

----- text -----

-- api widget
-- show lines of text contained in tbl
local function text(tbl, title)
	local first = 1
	local th = #tbl
	local w, h = 0, h
	local x, y
	local quit = false
	local evt
	
	for i = 1, #tbl do
		local lw = #tbl[i]
		if lw > w then w = lw end
	end
	
	tfx.attributes(config.fg, config.bg)
	x, y, w, h = frame(w, th, title)
	if #tbl > h then
		x, y, w, h = frame(w+1, th, title)
	end
	
	repeat
		x, y, w, h = frame(w, h, title)
		tfx.attributes(config.fg, config.bg)
		first = drawtext(tbl, first, x, y, w, h)
		tfx.present()
		
		evt = tfx.pollevent()
		if evt.key == tfx.key.ARROW_UP then
			first = first - 1
		elseif evt.key == tfx.key.ARROW_DOWN then
			first = first + 1
		elseif evt.key == tfx.key.PGUP then
			first = first - h
		elseif evt.key == tfx.key.PGDN then
			first = first + h
		elseif is_escape_key(evt) then
			quit = true
		end
	until quit
end

-- api
-- draw a potentially multi column list
local function drawtable(tbl, first, x, y, w, h, rrow)
error"not quite functional"
	sep = sep or config.sep
	local cols = #tbl[1]
	local colw = {}
	
	for r = 1, #tbl do
		local row = tbl[r]
		for c = 1, cols do
			local cw = row[c] and #tostring(row[c]) or 0
			if cw > colw[c] then colw[c] = cw end
		end
	end

	local tw = (cols - 1) * #sep
	for i = 1, cols do
		tw = tw + colw[i]
	end
	
	-- adjust column width
	if tw > w then
		local ntw = w - (cols - 1) * #sep
		local rtw = tw - (cols - 1) * #sep
		local wfac = ntw / rtw
		
		for i = 1, cols - 1 do
			colw[i] = math.floor(colw[i] * wfac)
			ntw = ntw - colw[i]
		end
		colw[cols] = ntw
	end
	
	if #tbl - first + 1 <= h then
		first = #tbl - h + 1
		if first < 1 then
			first = 1
			h = #tbl
		end
	end
	
	for i = 1, h do
		local row = tbl[first - i + 1]
		tfx.printat(x, y, row[1])
		local w = colw[1]
		for c = 2, #cols do
			drawstring(w, y - 1 + i, sep)
			drawstring(w + #sep, y - 1 + i, col[c], colw[c])
			w = w + #sep + colw[c]
		end
	end
end

----- ask -----

-- api widget
-- ask the user something, providing a table of buttons for answers.
-- Default is { "Yes", "No" }
-- Returns the number and the text of the selected button, or nil on abort
local function ask(msg, btns, title)
	local sel = 1
	btns = btns or { "Yes", "No" }

	tfx.attributes(config.fg, config.bg)

	local bw = #btns[1]
	for i = 2, #btns do
		bw = bw + 1 + #btns[i]
	end

	local tw = tfx.width()
	local ma = format(msg, tw / 2)
	local mw = bw
	for i = 1, #ma do
		if #ma[i] > mw then mw = #ma[i] end
	end
	local x, y, w, h = frame(mw, #ma+1, title)
	drawlist(ma, 1, x, y, w, h)	


	repeat
		local bp = math.floor(w - bw) / 2
		if bp < 1 then bp = 1 end
		local bw = w - bp + 1
		for i = 1, #btns do
			if i == sel then
				tfx.attributes(config.sel_fg, config.sel_bg)
			else
				tfx.attributes(config.elem_fg, config.elem_bg)
			end
			tfx.printat(x - 1 + bp, y + #ma, btns[i], bw - bp + 1)
			bp = bp + 1 + #btns[i]
			if bp > bw then break end
		end
		tfx.present()
	
		evt = tfx.pollevent()
		if evt then
			if evt.key == tfx.key.ENTER then
				return sel
			elseif evt.key == tfx.key.TAB or evt.key == tfx.key.ARROW_RIGHT then
				sel = sel < #btns and sel + 1 or 1
			elseif evt.key == tfx.key.ARROW_LEFT then
				sel = sel > 1 and sel - 1 or #btns
			end
		end
		
	until is_escape_key(evt, true)
	return nil
end

----- message -----

-- api widget
-- shows a message.
local function message(msg, title)
	tfx.attributes(config.fg, config.bg)

	local tw = tfx.width()
	local ma = format(msg, tw / 2)
	local mw = 0
	for i = 1, #ma do
		if #ma[i] > mw then mw = #ma[i] end
	end
	local x, y, w, h = frame(mw, #ma+1, title)
	drawlist(ma, 1, x, y, w, h)
	
	tfx.attributes(config.sel_fg, config.sel_bg)
	tfx.printat(x + (w / 2 - 1), y + #ma, "OK", 2)
	
	tfx.present()
	repeat
		local evt = tfx.pollevent()
	until is_escape_key(evt)
end

----- input -----

-- input a single value
local function drawvalue(t, f, x, y, w)
	local m = #t
	if f + w - 1 >= m then m = f + w - 1 end
	for i = f, m do
		if i - f < w then
			local ch = t[i] or '_'
			tfx.setcell(x + i - f, y, ch)
		end
	end
end

local function input(x, y, w, orig)
	local f = 1
	local pos = 1
	local res = {}
	if orig then
		string.gsub(tostring(orig), "(.)", function(c) res[#res+1] = c end)
		pos = #res + 1
	end

	local evt
	repeat
		if pos - f >= w then
			f = pos - w + 1
		elseif pos < f then
			f = pos
		end

		drawvalue(res, f, x, y, w)
		tfx.setcursor(x + pos - f, y)
		tfx.present()

		evt = tfx.pollevent()
		local ch = evt.char
		if evt.key == tfx.key.SPACE then ch = " " end
		if ch >= ' ' then
			table.insert(res, pos, ch)
			pos = pos + 1
		elseif (evt.key == tfx.key.BACKSPACE or evt.key == tfx.key.BACKSPACE2)  and pos > 1 then
			table.remove(res, pos-1)
			pos = pos - 1
		elseif evt.key == tfx.key.DELETE  and pos <= #res then
			table.remove(res, pos)
			if pos > #res and pos > 1 then pos = pos - 1 end
		elseif evt.key == tfx.key.ARROW_LEFT and pos > 1 then
			pos = pos - 1
		elseif evt.key == tfx.key.ARROW_RIGHT and pos <= #res then
			pos = pos + 1
		elseif evt.key == tfx.key.HOME then
			pos = 1
		elseif evt.key == tfx.key.END then
			pos = #res + 1
		elseif evt.key == tfx.key.ESC then
			return nil
		end
	until is_escape_key(evt) or evt.key == tfx.key.TAB or evt.key == tfx.key.ARROW_UP or evt.key == tfx.key.ARROW_DOWN
	tfx.hidecursor()

	return table.concat(res), evt.key
end

-- api widget
-- select an item from a list. Returns the number of the selected item.

local function select_renderrow(row, s, x, y, w, extra)
	if row == extra.selected then
		tfx.attributes(config.sel_fg, config.sel_bg)
	end
	drawfield(x, y, s, w)
end

local function select(tbl, title)
	tfx.attributes(config.fg, config.bg)
error "incomplete"
	local w = 0
	for i=1, #tbl do
		if #tbl[i] > w then w = #tbl[i] end
	end
	
	local x, y, w, h = frame(w, #tbl, title)
	local extra = { selected = 1 }
	
	local pos = 1
	repeat
		drawlist(tbl, 1, x, y, w, h, select_renderrow, extra)
		tfx.present()
	
		local evt = tfx.pollevent()
		-- ...
	until is_escape_key(evt)
	
	return tbl[pos], pos
end

----- drawstatus -----

-- api
-- draw a status bar. The last element in tbl is always right aligned,
-- the rest is left aligned.
local function drawstatus(tbl, y, w, sep)
	sep = sep or '|'
	tfx.attributes(config.elem_fg, config.elem_bg)
	local w = tfx.width()
	local tw = 1
	
	for i=2, #tbl - 1 do
		tw = tw + #sep + #tbl[i]
	end
	
	tfx.printat(1, y, string.rep(' ', w))
	tfx.printat(1, y, tbl[1])
	local p = #tbl[1] + 1
	for i = 2, #tbl - 1 do
		tfx.printat(p, y, sep)
		tfx.printat(p + #sep, y, tbl[i])
		p = p + #tbl[i] + #sep
	end
	
	tfx.setcell(w - #tbl[#tbl], y, ' ')
	tfx.printat(w + 1 - #tbl[#tbl], y, tbl[#tbl])
end

----- configure -----

-- api
-- change config options for the ui lib. see resetconfig() above for options
local function configure(tbl)
	for k, v in pairs(tbl) do
		if config[k] then
			if type(v) == type(config[k]) then
				config[k] = v
			else
				error("invalid value type for config option '"..k.."': "..type(v), 2)
			end
		else
			error("invalid config option '"..k.."'", 2)
		end
	end
end

----- outputmode -----

-- api
-- overwrite tfx outputmode function: do the same but also reset all
-- colors to default. This is because with the change of the output mode,
-- the colors may also change.
local function outputmode(m)
	local om = tfx.outputmode(m)
	if m then resetconfig() end
	return om
end

----- initialize -----

-- [[
tfx.init()
tfx.outputmode(tfx.output.NORMAL)
tfx.inputmode(tfx.input.ESC)
resetconfig()
--]]

----- return -----

return setmetatable({
	-- utilities
	drawframe = drawframe,
	frame = frame,
	drawlist = drawlist,
	drawtext = drawtext,
	drawstatus = drawstatus,
	drawfield = drawfield,

	input = input,


	-- widgets
	text = text,
	message = message,
	ask = ask,
	select = select,

	-- misc
	configure = configure,
	getconfig = getconfig,
	outputmode = outputmode,
}, { __index = tfx })
