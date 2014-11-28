--[[
	complete lua 5.3 syntax

	chunk ::= block

	block ::= {stat} [retstat]

	stat ::=  ';' | 
		 varlist '=' explist | 
		 functioncall | 
		 label | 
		 'break' | 
		 'goto' Name | 
		 'do' block 'end' | 
		 'while' exp 'do' block 'end' | 
		 'repeat' block 'until' exp | 
		 'if' exp 'then' block {'elseif' exp 'then' block} ['else' block] 'end' | 
		 'for' Name '=' exp ',' exp [',' exp] 'do' block 'end' | 
		 'for' namelist 'in' explist 'do' block 'end' | 
		 'function' funcname funcbody | 
		 'local' 'function' Name funcbody | 
		 'local' namelist ['=' explist] 

	retstat ::= 'return' [explist] [';']

	label ::= '::' Name '::'

	funcname ::= Name {'.' Name} [':' Name]

	varlist ::= var {',' var}

	var ::=  Name | prefixexp '[' exp ']' | prefixexp '.' Name 

	namelist ::= Name {',' Name}

	explist ::= exp {',' exp}

	exp ::=  'nil' | 'false' | 'true' | Numeral | LiteralString | '...' | functiondef | 
		 prefixexp | tableconstructor | exp binop exp | unop exp 

	prefixexp ::= var | functioncall | '(' exp ')'

	functioncall ::=  prefixexp args | prefixexp ':' Name args 

	args ::=  '(' [explist] ')' | tableconstructor | LiteralString 

	functiondef ::= 'function' funcbody

	funcbody ::= '(' [parlist] ')' block 'end'

	parlist ::= namelist [',' '...'] | '...'

	tableconstructor ::= '{' [fieldlist] '}'

	fieldlist ::= field {fieldsep field} [fieldsep]

	field ::= '[' exp ']' '=' exp | Name '=' exp | exp

	fieldsep ::= ',' | ';'

	binop ::=  '+' | '-' | '*' | '/' | '//' | '^' | '%' | 
		 '&' | '~' | '|' | '>>' | '<<' | '..' | 
		 '<' | '<=' | '>' | '>=' | '==' | '~=' | 
		 'and' | 'or'

	unop ::= '-' | 'not' | '#' | '~'
--]]

local function mkset(t)
	local r = {}
	for _, v in ipairs(t) do r[v] = true end
	return r
end

local keywords = mkset { 'break', 'goto', 'do', 'end', 'while', 'repeat',
	'until', 'if', 'then', 'elseif', 'else', 'for', 'function', 'local',
	'return' }

local binop = mkset { '+', '-', '*', '/', '//', '^', '%', '&', '~', '|',
		'>>', '<<', '..', '<', '<=', '>', '>=', '==', '~=', 'and', 'or' }

local unop = mkset { '-', 'not', '#', '~' }

local val = mkset { 'nil', 'true', 'false' } -- , number, string

local other = mkset { '=', ':', ';', ',', '.', '[', ']', '(', ')', '{', '}',
		'...', '::' }

local find = string.find

local function lex_space(str, pos)
	local s, e = find(str, "^%s+", pos)
	if not s then return nil end
	return "spc", pos, e
end

local function lex_longstr(str, pos)
	local s, e = find(str, "^%[=*%[", pos)
	if not s then return nil end
	local ce = "]" .. string.rep('=', e-s-1) .. "]"
	s, e = find(str, ce, e+1, true)
	if not s then return nil, "unfinished string" end
	return "str", pos, e
end

local function lex_shortstr(str, pos)
	local s, e = find(str, '["\']', pos)
	if not s then return nil end
	local ch = string.sub(str, s, e)
	s, e = find(str, '^'..ch, pos+1)
	if not s then s, e = find(str, '[^\\]'..ch, pos+1) end
	if not s then return nil, "unfinished string" end
	return "str", pos, e
end

local function lex_name(str, pos)
	local s, e = find(str, "^[%a_][%w_]*", pos)
	if not s then return nil end
	local t = "name"
	local ss = string.sub(str, s, e)
	if keywords[ss] then
		t = "key"
	elseif unop[ss] or binop[ss] then
		t = "op"
	elseif val[ss] then
		t = "val"
	end
	return t, pos, e
end

local function lex_number(str, pos)
	local t = num
	local p = pos
	local s, e = find(str, "^0[xX]", p)
	if s then
		p = e + 1
		s, e = find(str, "^%x+", p)
		if e then p = e + 1 end
		s, e = find(str, "^%.%x" .. (s and '*' or '+'), p)
		if e then p = e + 1 end
		s, e = find(str, "^[pP][+-]?%d+", p)
		if not e then e = p - 1 end
		if e == pos+2 then return nil end
	else
		s, e = find(str, "^%d+", p)
		if e then p = e + 1 end
		s, e = find(str, "^%.%d" .. (s and '*' or '+'), p)
		if e then p = e + 1 end
		s, e = find(str, "^[eE][+-]?%d+", p)
		if not e then e = p - 1 end
		if e < pos then return nil end
	end
	return "num", pos, e
end

local function lex_comment(str, pos)
	local s, e = find(str, "^%-%-", pos)
	local t
	if not s then return nil end
	t, s, e = lex_longstr(str, pos+2)
	if not s then
		s, e = find(str, "^--[^\n]+\n", pos)
		e = e - 1
	elseif not t then
		return nil, "unfinished comment"
	end
	return "com", pos, e
end

local function lex_op(str, pos)
	local s, e = find(str, "^[/<>=~.]+", pos)
	if not s then s, e = find(str, "^[+%-*^%&~|#]", pos) end
	if not s then return nil end
	local op = string.sub(str, s, e)
	if binop[op] or unop[op] then
		return "op", s, e
	end
	return nil
end

local function lex_other(str, pos)
	local s, e = find(str, "^[=:.]+", pos)
	if not s then s, e = find(str, "^[;,%[%](){}]", pos) end
	if not s then return nil end
	local op = string.sub(str, s, e)
	if other[op] then
		return "other", s, e
	end
	return nil
end

local function lualexer(str, skipws)
	local cr = coroutine.create(function()
		local pos = 1
		local line, col = 1, 1
		local ch, t, s, e, l, c
		
		while pos <= #str do
			ch = string.sub(str, pos, pos)
			if ch == '-' then
				t, s, e = lex_comment(str, pos)
				if not s then
					t, s, e = lex_op(str, pos)
				end
			elseif ch == "[" then
				t, s, e = lex_longstr(str, pos)
				if not s then
					t, s, e = lex_other(str, pos)
				end
			elseif ch == "'" or ch == '"' then
				t, s, e = lex_shortstr(str, pos)
			elseif find(ch, "[%a_]") then
				t, s, e = lex_name(str, pos)
			elseif find(ch, "%d") then
				t, s, e = lex_number(str, pos)
			elseif find(ch, "%p") then
				t, s, e = lex_number(str, pos)
				if not s then
					t, s, e = lex_op(str, pos)
				end
				if not s then
					t, s, e = lex_other(str, pos)
				end
			else
				t, s, e = lex_space(str, pos)
			end

			if s ~= pos then error("internal error") end

			l, c = line, col
			if t then
				local s1 = string.find(str, "\n", s)
				while s1 and s1 <= e do
					col = 1
					line = line + 1
					s = s1 + 1
					s1 = string.find(str, "\n", s)
				end
				col = col + (s > e and 0 or e - s + 1)
			else
				col = col + 1
			end

			if t and (not skipws or t ~= "spc") then
				coroutine.yield(t, pos, e, l, c)
			elseif not t then
				s = s or "invalid token"
				coroutine.yield(nil, s .. " in line " .. l .. " char " .. c)
				e = pos
			end
			pos = e + 1
		end
		return nil
	end)
	
	return function()
		local ok, t, s, e, l, c = coroutine.resume(cr)
		if ok then
			return t, s, e, l, c
		end
		return nil, t
	end
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

-- very simple for the time being: we consider every line that has a
-- token other than com or spc breakable.
local function lualoader(file)
	local srct = {}
	local canbrk = {}
	
	if file then
		local f = io.open(file, "r")
		if not f then
			return nil, "could not load source file "..file
		end
		local src = f:read("*a")
		f:close()
		
		local tokens = lualexer(src)
		for t, s, e, l, c in tokens do
			if t ~= 'com' and t ~= 'spc' then
				canbrk[l] = true
			end
		end

		src = expand_tabs(src, 4)
		string.gsub(src, "([^\r\n]*)\r?\n", function(s) table.insert(srct, s) end)
	end
	
	return { txt = srct, lines = #srct, canbrk = canbrk, breakpts = {}, selected = 0 }
end

return lualoader
