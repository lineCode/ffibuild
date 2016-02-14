if RELOAD then
	_G.RELOAD = nil
	--include("/media/caps/ssd_840_120gb/ffibuild/ffibuild/examples/sdl/build.lua")
	include("/media/caps/ssd_840_120gb/ffibuild/ffibuild/examples/libpurple/build.lua")
	return
end

local ffibuild = {}

function ffibuild.BuildCHeader(c_source, flags)
	flags = flags or ""
	local temp_name = os.tmpname()
	local temp_file = io.open(temp_name, "w")
	temp_file:write(c_source)
	temp_file:close()

	local gcc = io.popen("gcc -xc -E -P " .. flags .. " " .. temp_name)
	local header = gcc:read("*all")

	gcc:close()
	os.remove(temp_name)

	return header
end

function ffibuild.SplitHeader(header, ...)
	header = header:gsub("/%*.-%*/", "")

	local found = {}

	for _, what in ipairs({...}) do
		local _, stop_pos = header:find(".-" .. what)

		if stop_pos then
			stop_pos = stop_pos - #what
		end
		table.insert(found, stop_pos)
	end

	table.sort(found, function(a, b) return a < b end)

	local stop = found[1]

	for i = 1, math.huge do
		local char = header:sub(stop - i, stop - i)
		if char == ";" or char == "}" then
			stop = stop - i + 1
			break
		end
	end

	return header:sub(0, stop), header:sub(stop)
end

function ffibuild.GetMetaData(header)

	local meta_data = {
		functions = {},
		structs = {},
		unions = {},
		typedefs = {},
		variables = {},
		enums = {},
		global_enums = {},
	}

	do -- cleanup header
		-- this assumes the header has been preprocessed with gcc -E -P
		header = " " .. header

		-- process all single quote strings
		header = header:gsub("('%S+')", function(val) return assert(loadstring("return (" .. val .. "):byte()"))() end)
		header = header:gsub("' '", string.byte(" "))

		-- remove comments
		header = header:gsub("/%*.-%*/", "")

		-- remove things like #pragma
		header = header:gsub("#.-\n", "")

		 -- normalize everything to have equal spacing even between punctation
		header = header:gsub("([*%(%){}&%[%],;&|<>])", " %1 ")
		header = header:gsub("%s+", " ")

		-- insert a newline after ;
		header = header:gsub(";", ";\n")

		-- this will explode structs and and whatnot so make sure we remove newlines inside {} and ()
		header = header:gsub("%b{}", function(s) return s:gsub("%s+", " ") end)
		header = header:gsub("%b()", function(s) return s:gsub("%s+", " ") end)

		-- remove compiler __attribute__
		header = header:gsub("__%a-__ %b() ", "")

		-- remove __extension__
		header = header:gsub("__extension__ ", "")

		-- remove __restrict
		header = header:gsub("__restrict__ ", "")
		header = header:gsub("__restrict", "")

		-- remove volatile
		header = header:gsub(" volatile ", " ")

		-- remove inline functions
		header = header:gsub(" static __inline.-%b().-%b{}", "")
		header = header:gsub(" static inline.-%b().-%b{}", "")

		header = header:gsub(" extern __inline.-%b().-%b{}", "")
		header = header:gsub(" extern inline.-%b().-%b{}", "")

		-- int foo(void); >> int foo();
		header = header:gsub(" %( void %) ", " ( ) ")

		-- foo bar[?] > foo *bar
		header = header:gsub(" ([%a%d_]+) %b[] ", " * %1 ")
	end

	local function is_function(str) return str:find("^.+%b() $") end
	local function is_function_pointer(str) return str:find("^.-%(.-%*.-%).-%b() $") end

	for line in header:gmatch(" (.-);\n") do

		local extern
		local typedef

		if line:find("^typedef") then
			typedef = true
			line = line:match("^typedef (.+)")

			if is_function_pointer(line) then
				local type = ffibuild.CreateType("function", line:sub(0, -2), true)
				meta_data.typedefs[type.name] = type
				line = nil
			elseif is_function(line) then
				local alias = line:match(".- ([%a%d_]+) %b()")
				meta_data.typedefs[alias] = ffibuild.CreateType("function", line:sub(0, -2))
			else
				local content, alias = line:match("^(.+) ([%a%d_]+)")

				if content:find("^struct ") or content:find("^union ") or content:find("^enum ") then
					local tag, found = content:gsub(" %b{}", "")

					if not tag:find("%s") then
						tag = tag .. " " .. alias
						content = content:gsub("^(%l+ )", tag .. " ")
					end

					meta_data.typedefs[alias] = ffibuild.CreateType("type", tag)

					if found == 0 then
						line = nil
					else
						line = content
					end
				else
					meta_data.typedefs[alias] = ffibuild.CreateType("type", content)

					line = nil
				end
			end
		elseif line:find("^extern") then
			extern = true
			line = line:match("^extern (.+)")
		elseif line:find("^static") then
			print(line)
		end

		if line then
			if is_function_pointer(line) then
				local type = ffibuild.CreateType("function", line:sub(0, -2), true)
				meta_data.functions[type.name] = type
			elseif is_function(line) then
				local type = ffibuild.CreateType("function", line:sub(0, -2))
				meta_data.functions[type.name] = type
			elseif line:find("^enum") then
				local tag, content = line:match("(enum [%a%d_]+) ({.+})")

				if tag then
					meta_data.enums[tag] = ffibuild.CreateType("enums", content, meta_data)
					meta_data.enums[tag].name = tag
				else
					content = line:match("enum ({.+})")
					-- no type name = global enum
					table.insert(meta_data.global_enums, ffibuild.CreateType("enums", content, meta_data))
				end
			elseif line:find("^struct") or line:find("^union") then
				local keyword = line:match("^([%a%d_]+)")


				local tag, content = line:match("("..keyword.." [%a%d_]+) ({.+})")

				if not tag then
					-- just a forward declaration or an opaque struct
					tag = line:match("("..keyword.." [%a%d_]+)")
					content = "{ }"
				end

				local tbl = keyword == "struct" and meta_data.structs or meta_data.unions
				tbl[tag] = ffibuild.CreateType("struct", content, keyword == "union", meta_data)
			elseif extern then
				local tag, name = line:match("^(.+) ([%a%d_]+) $")
				meta_data.variables[name] = ffibuild.CreateType("type", tag)
			end
		end
	end

	function meta_data:GetStructTypes(pattern)
		local out = {}

		-- find all types that start with *pattern* and are also structs
		for type_name, type in pairs(self.typedefs) do
			local name = type_name:match(pattern)
			if name and type:GetSubType() == "struct" then
				table.insert(out, {
					name = name,
					type = type,
				})
			end
		end

		-- sort them by length to avoid functions like purple_>>conversation<<_foo_bar() to conflict with purple_>>conversation_im<<_foo_bar()
		table.sort(out, function(a, b) return #a.name > #b.name end)

		return out
	end

	function meta_data:GetFunctionsStartingWithType(type)
		local out = {}

		for func_name, func_type in pairs(self.functions) do
			if func_type.arguments then
				local evaluated = func_type.arguments[1]:GetPrimitive(self) or func_type.arguments[1]
				if evaluated:GetBasicType() == type:GetBasicType() then
					out[func_name] = func_type
				end
			end
		end

		return out
	end

	function meta_data:FindFunctions(pattern, from, to)
		local out = {}
		for func_name, func_type in pairs(self.functions) do
			local capture = func_name:match(pattern)
			if capture then
				if from and to then
					capture = ffibuild.ChangeCase(capture, from, to)
				end
				out[capture] = func_type
			end
		end
		return out
	end

	return meta_data
end

function ffibuild.ChangeCase(str, from, to)
	if from == "fooBar" then
		if to == "FooBar" then
			return str:sub(1, 1):upper() .. str:sub(2)
		elseif to == "foo_bar" then
			return ffibuild.ChangeCase(str:sub(1, 1):upper() .. str:sub(2), "FooBar", "foo_bar")
		end
	elseif from == "FooBar" then
		if to == "foo_bar" then
			return str:gsub("(%l)(%u)", function(a, b) return a.."_"..b:lower() end):lower()
		elseif to == "fooBar" then
			return str:sub(1, 1):lower() .. str:sub(2)
		end
	elseif from == "foo_bar" then
		if to == "FooBar" then
			return ("_" .. str):gsub("_(%l)", function(s) return s:upper() end)
		elseif to == "fooBar" then
			return ffibuild.ChangeCase(ffibuild.ChangeCase(str, "foo_bar", "FooBar"), "FooBar", "fooBar")
		end
	end
	return str
end

do -- type metatables
	local metatables = {}

	for _, name in ipairs({"function", "struct", "type", "var_arg", "enums"}) do
		local META = {}
		META.__index = META
		META.MetaType = name

		--META.__tostring = function(s) return ("%s[%s]"):format(s:GetDeclaration(), name) end

		function META:GetDeclaration(meta_data, ...) end
		function META:GetPrimitive() return self end
		function META:GetCopy() end
		function META:GetBasicType() end
		function META:GetSubType() return self:GetBasicType() end
		function META:FetchRequired(meta_data, out, temp) temp = temp or {} table.insert(out, 1, self) end

		metatables[name] = META
	end

	function ffibuild.CreateType(type, ...)
		return setmetatable(metatables[type]:Create(...), metatables[type])
	end

	do -- enums
		local ENUMS = metatables.enums

		local operators = {}

		local LR = function(operator, name)
			local func = bit[name]
			operators[operator] = setmetatable({find = operator:gsub("(.)", "%%%1"), replace = "%%_O['"..operator.."']%%"}, {__mod = function(a) return setmetatable({}, {__mod = function(_,b) return func(a, b) end}) end})
		end

		local L = function(operator, name)
			local func = bit[name]
			operators[operator] = setmetatable({find = operator:gsub("(.)", "%%%1"), replace = "_O['"..operator.."']"}, {__call = function(_, a) return func(a) end})
		end

		LR("&", "band")
		LR("|", "bor")
		LR("^", "bxor")
		LR("<<", "lshift")
		LR(">>", "rshift")
		L("~", "bnot")

		local function parse_bit_declaration(expression)
			expression = expression:gsub("([%d%.xabcdefABCDEF]+)", "(%1)")

			for operator, info in pairs(operators) do
				expression = expression:gsub(info.find, info.replace)
			end

			local func, err = loadstring("local _O = ... return " .. expression)
			if func then
				local ok, msg = pcall(func, operators)
				if ok then
					return msg
				end
				error("unable to run '"..expression.."' : " .. msg)
			end
			error("unable to parse '"..expression.."': " .. err)
		end

		local function find_enum(current_meta_data, out, what)
			for _, info in ipairs(out) do
				if info.key == what then
					return info.val
				end
			end

			for _, info in pairs(current_meta_data.global_enums) do
				for _, info in ipairs(info.enums) do
					if info.key == what then
						return info.val
					end
				end
			end

			for _, info in pairs(current_meta_data.enums) do
				for _, info in ipairs(info.enums) do
					if info.key == what then
						return info.val
					end
				end
			end
		end

		function ENUMS:Create(declaration, current_meta_data)
			declaration = declaration:sub(3, -3)

			local num = 0
			local enums = {}

			for line in (declaration .. " , "):gmatch("(.-) , ") do
				local key, val = line:match("(.+) = (.+)")

				if key and val then
					num = tonumber(val)

					if not num then
						val = val:gsub("> >", ">>"):gsub("< <", "<<")

						do
							local test, found = val:gsub("(%a[%a%d_]+)", function(what)
								local val = find_enum(current_meta_data, enums, what)

								if val then
									found = true
									return val
								end

								-- don't bother with type casting
								local type = current_meta_data.typedefs[what]

								if type then
									return "_REMOVE_ME_"
								end
							end)

							-- remove all typecasts
							if test:find("_REMOVE_ME_") then
								test = test:gsub("%( _REMOVE_ME_ %) ", "")
							end

							if found > 0 then
								val = test
							else
								val = find_enum(current_meta_data, enums, val) or val

								local test = tonumber(val)

								if test then
									num = test
								end
							end
						end
					end

					if not num then
						num = parse_bit_declaration(val)
					end

					if not num then
						error("unable to parse enum:\n\t" .. val)
					end
				else
					key = line
				end

				table.insert(enums, {key = key, val = num})

				num = num + 1
			end

			return {enums = enums}
		end

		function ENUMS:GetCopy() return self end

		function ENUMS:GetDeclaration(meta_data, check_enums)

			local str = {}

			for i, info in ipairs(self.enums) do
				if not check_enums or check_enums(info.key, info) then
					table.insert(str, info.key .. " = " .. info.val)
				end
			end

			if check_enums and #str == 0 then return end

			str = table.concat(str, ", ")

			if self.name then
				return "typedef " .. self.name .. " { " .. str .. " };"
			else
				return "enum {\n" .. str .. "\n};"
			end
		end

		function ENUMS:GetBasicType()
			return "enum"
		end
	end

	do -- type
		local TYPE = metatables.type

		local flags = {
			const = true,
			volatile = true,
			struct = true,
			enum = true,
			union = true,
			unsigned = true,
			signed = true,
			pointer = true,
		}

		function TYPE:Create(declaration)
			local tree = {}

			local node = tree

			local prev_token
			local prev_node

			for token in declaration:reverse():gmatch("(%S+) ?") do
				token = token:reverse()

				if token == "*" then
					token = "pointer"
				end

				if flags[token] then
					node[token] = true
				else
					node.type = token
				end

				if token == "struct" or token == "union" or token == "enum" then
					prev_node[prev_token] = nil
					node.type = token .. " " .. prev_token
				end

				if token == "pointer" then
					prev_node = node
					node.to = {}
					node = node.to
				end

				prev_token = token
				prev_node = node
			end

			return {
				last_node = node,
				tree = tree,
			}
		end

		function TYPE:GetDeclaration(meta_data, type_replace, ...)
			local type = self:GetPrimitive(meta_data)

			if not type.tree then return type:GetDeclaration(meta_data) end

			local node = type.tree

			local declaration = {}

			while true do
				if node.type then
					table.insert(declaration, (type_replace or node.type):reverse())
				end

				for _, flag in ipairs({"signed", "unsigned", "const", "volatile"}) do
					if node[flag] then
						table.insert(declaration, flag:reverse())
					end
				end

				if node.pointer then
					table.insert(declaration, "*")
					node = node.to
				else
					break
				end
			end

			return table.concat(declaration, " "):reverse()
		end

		function TYPE:GetBasicType(meta_data)
			if meta_data then return self:GetPrimitive(meta_data):GetBasicType() end
			return self.last_node.type
		end

		function TYPE:GetSubType()
			if self.last_node.struct then return "struct" end
			if self.last_node.enum then return "enum" end
			if self.last_node.union then return "union" end

			return self:GetBasicType()
		end

		function TYPE:GetCopy()
			local copy = ffibuild.CreateType("type", self:GetDeclaration())

			for k,v in pairs(self) do
				if type(v) ~= "table" then
					copy[k] = v
				end
			end

			return copy
		end

		function TYPE:GetPrimitive(meta_data)
			if not meta_data or not meta_data.typedefs[self:GetBasicType()] then return self end

			local copy = self
			local type = copy

			for _ = 1, 10 do
				type = meta_data.typedefs[type:GetBasicType()]

				if not type then break end

				local type = type:GetCopy(meta_data)

				if getmetatable(type) ~= getmetatable(copy) then
					local name = copy.name
					for k in pairs(copy) do copy[k] = nil end
					for k,v in pairs(type) do copy[k] = v end
					copy.name = name

					setmetatable(copy, getmetatable(type))

					return copy:GetPrimitive(meta_data)
				elseif type.tree then
					copy.last_node.type = nil
					for k, v in pairs(type.tree) do
						copy.last_node[k] = v
					end
					if type.last_node ~= type.tree then
						copy.last_node = type.last_node
					end
				else
					break
				end
			end

			return copy
		end

		function TYPE:FetchRequired(meta_data, out, temp)
			temp = temp or {}

			local primitive = self:GetPrimitive(meta_data)
			local basic_type = primitive:GetBasicType()

			if temp[basic_type] then
				for i,v in ipairs(out) do
					if v:GetBasicType() == basic_type then
						table.remove(out, i)
						table.insert(out, 1, v)
						return
					end
				end
			else
				table.insert(out, 1, primitive)
			end

			temp[basic_type] = true

			if meta_data then
				if meta_data.structs[basic_type] then
					meta_data.structs[basic_type]:FetchRequired(meta_data, out, temp)
				elseif meta_data.unions[basic_type] then
					meta_data.unions[basic_type]:FetchRequired(meta_data, out, temp)
				end
			end
		end
	end

	do -- function
		local FUNCTION = metatables["function"]

		local basic_types = {
			["char"] = true,
			["signed char"] = true,
			["unsigned char"] = true,
			["short"] = true,
			["short int"] = true,
			["signed short"] = true,
			["signed short int"] = true,
			["unsigned short"] = true,
			["unsigned short int "] = true,
			["int"] = true,
			["signed"] = true,
			["signed int"] = true,
			["unsigned"] = true,
			["unsigned int"] = true,
			["long"] = true,
			["long int"] = true,
			["signed long"] = true,
			["signed long int"] = true,
			["unsigned long"] = true,
			["unsigned long int"] = true,
			["long long"] = true,
			["long long int"] = true,
			["signed long long"] = true,
			["signed long long int"] = true,
			["unsigned long long"] = true,
			["unsigned long long int"] = true,
			["float"] = true,
			["double"] = true,
			["long double"] = true,
		}

		local function explode(str, split)

			local temp = {}
			str = str:gsub("(%b())", function(str) table.insert(temp, str) return "___TEMP___" end)

			local out = {}

			for val in (str .. split):gmatch("(.-)"..split) do
				if val:find("___TEMP___", nil, true) then val = val:gsub("___TEMP___", function() return table.remove(temp, 1) end) end
				table.insert(out, val)
			end

			return out
		end

		function FUNCTION:Create(declaration, is_callback)
			local return_line, func_name, arg_line, func_type

			if is_callback then
				return_line, func_type, func_name, arg_line = declaration:match("^(.-)%( (%*.*) ([%a%d_]+) %) (%b())$")
				if not return_line then
					return_line, func_type, func_name, arg_line = declaration:match("^(.-)%( %( (%*.*) ([%a%d_]+) %) (%b()) %)$")
				end
			else
				return_line, func_name, arg_line = declaration:match("(.-) ([%a%d_]+) (%b())")
			end

			arg_line = arg_line:sub(3, -3)

			local arguments

			if #arg_line > 0 then
				arguments = explode(arg_line, " , ")
				for i, arg in ipairs(arguments) do
					local type

					if arg == "..." then
						type = ffibuild.CreateType("var_arg", arg)
					elseif basic_types[arg] then
						type = ffibuild.CreateType("type", arg)
					elseif arg:find("%b() %b()") then
						type = ffibuild.CreateType("function", arg, true)
					else
						local declaration, name = arg:match("^([%a%d%s_%*]-) ([%a%d_]-)$")

						if not declaration then
							declaration = arg
							name = "unknown"
						end

						type = ffibuild.CreateType("type", declaration)
						type.name = name
					end

					arguments[i] = type
				end
			end

			return {
				name = func_name,
				arguments = arguments,
				return_type = ffibuild.CreateType("type", return_line),
				callback = is_callback,
				func_type = func_type,
			}
		end

		function FUNCTION:GetCopy()
			-- TODO: this doesn't work because i :Create does not handle callbacks that return callbacks
			--return ffibuild.CreateType("function", self:GetDeclaration(), self.callback)
			local copy = {}

			for k,v in pairs(self) do
				if k == "return_type" then
					copy[k] = v:GetCopy()
				elseif k == "arguments" then
					local new_arguments = {}
					for i,v in ipairs(v) do
						new_arguments[i] = v:GetCopy()
					end
					copy[k] = new_arguments
				else
					copy[k] = v
				end
			end

			return setmetatable(copy, FUNCTION)
		end

		function FUNCTION:GetPrimitive(meta_data)
			local copy = self:GetCopy()

			return copy
		end

		function FUNCTION:GetBasicType()
			return self.callback and "callback" or "function"
		end

		function FUNCTION:GetSubType()
			return self:GetBasicType()
		end

		function FUNCTION:GetDeclaration(meta_data, as_callback, name)

			local arg_line = {}

			if self.arguments then
				for i, arg in ipairs(self.arguments) do
					arg_line[i] = arg:GetDeclaration(meta_data)
				end
			end

			arg_line = "( " .. table.concat(arg_line, " , ") .. " )"

			if self.return_type.callback then
				local ret, urn = self.return_type:GetDeclaration(meta_data):match("^(.-%( %*) (.+)")
				local res = ret .. " " .. self.name .. " " .. arg_line .. " " .. urn

				return res
			end

			if self.callback or as_callback == true then
				if name then
					return self.return_type:GetDeclaration(meta_data) .. " ( " .. (self.func_type or "* ") .. name .. " ) " .. arg_line
				else
					return self.return_type:GetDeclaration(meta_data) .. " ( " .. (self.func_type or "*") .. " ) " .. arg_line
				end
			else
				return self.return_type:GetDeclaration(meta_data)  .. " " .. self.name .. " " .. arg_line
			end
		end

		local keywords = {
			["and"] = true,
			["break"] = true,
			["do"] = true,
			["else"] = true,
			["elseif"] = true,
			["end"] = true,
			["false"] = true,
			["for"] = true,
			["function"] = true,
			["if"] = true,
			["in"] = true,
			["local"] = true,
			["nil"] = true,
			["not"] = true,
			["or"] = true,
			["repeat"] = true,
			["return"] = true,
			["then"] = true,
			["true"] = true,
			["until"] = true,
			["while"] = true,
		}

		function FUNCTION:GetParameters(meta, check)
			if not self.arguments then return "", "" end

			local done = {}

			local parameters = {}
			local call = {}

			for i, arg in ipairs(self.arguments) do
				local name = arg.name or "_" .. i

				if keywords[name] then
					name = name .. "_"
				end

				if meta and i == 1 then
					name = "self"
				end

				do -- fixes argument names that are the same
					if done[name] then
						name = name .. done[name]
					end

					done[name] = (done[name] or 0) + 1
				end

				table.insert(parameters, name)

				local res = check and check(arg, name) or name

				if res then
					table.insert(call, res)
				end
			end

			return table.concat(parameters, ", "), table.concat(call, ", ")
		end

		function FUNCTION:FetchRequired(meta_data, out, temp)
			temp = temp or {}

			self.return_type:FetchRequired(meta_data, out, temp)

			if self.arguments then
				for _, arg in ipairs(self.arguments) do
					arg:FetchRequired(meta_data, out, temp)
				end
			end
		end
	end

	do -- struct
		local STRUCT = metatables["struct"]

		local function explode(str, split)

			local temp = {}
			str = str:gsub("(%b{})", function(str) table.insert(temp, str) return "___TEMP___" end)

			local out = {}

			for val in str:gmatch("(.-)"..split) do
				if val:find("___TEMP___", nil, true) then val = val:gsub("___TEMP___", function() return table.remove(temp, 1) end) end
				table.insert(out, val)
			end

			return out
		end

		function STRUCT:Create(declaration, is_union, meta_data)
			declaration = declaration:sub(3, -2)

			local out = {}

			for _, line in ipairs(explode(declaration, " ; ")) do
				if line:find("^enum") then
					print(line)
				elseif line:find("^struct") or line:find("^union") then
					local keyword = line:match("^([%a%d_]+)")

					if line:find("%b{}") then
						local tag, content, name = line:match("^(" .. keyword .. " [%a%d_]+) ({.+}) (.+)")
						if not tag then
							content, name = line:match("^" .. keyword .. " ({.+}) (.+)")
						end

						if not content then
							content = line:match("^" .. keyword .. " ({.+})$")
							name = ""
							tag = ""
						end

						local type = ffibuild.CreateType("struct", content, keyword == "union")
						type.name = name
						type.tag = tag

						table.insert(out, type)

						if meta_data and tag then
							(keyword == "struct" and meta_data.structs or meta_data.unions)[tag] = type
						end
					else
						local declaration, name = line:match("^(" .. keyword .. " [%a%d%s_%*]-) ([%a%d_]-)$")

						local type = ffibuild.CreateType("type", declaration)
						type.name = name

						table.insert(out, type)
					end
				elseif line:find("%b() %b()") then
					table.insert(out, ffibuild.CreateType("function", line, true))
				elseif line:find(" , ") then
					local declaration, names = line:match("([%a%d_]+) (.+)")
					for name in (names .. " , "):gmatch("(.-) , ") do
						local type = ffibuild.CreateType("type", declaration)
						type.name = name
						table.insert(out, type)
					end
				elseif line:find(":") then
					local declaration, name = line:match("^([%a%d%s_%*]-) ([%a%d_:]-)$")


				else
					local declaration, name = line:match("^([%a%d%s_%*]-) ([%a%d_]-)$")

					local type = ffibuild.CreateType("type", declaration)
					type.name = name

					table.insert(out, type)
				end
			end

			return {
				data = out,
				struct = not is_union,
			}
		end

		function STRUCT:GetCopy()
			local copy = {data = {}, struct = self.struct}
			for i,v in ipairs(self.data) do
				copy.data[i] = v:GetCopy()
				copy.data[i].name = v.name
			end
			return setmetatable(copy, STRUCT)
		end

		function STRUCT:GetBasicType()
			return self.struct and "struct" or "union"
		end

		function STRUCT:GetSubType()
			return self:GetBasicType()
		end

		function STRUCT:GetPrimitive(meta_data)
			local copy = self:GetCopy()

			return copy
		end

		function STRUCT:GetDeclaration(meta_data)

			local str = " { "
			for _, type in ipairs(self.data) do
				if type.MetaType == "function" then
					str = str .. type:GetDeclaration(meta_data, true, type.name) .. " ; "
				elseif type.MetaType == "struct" then
					str = str .. type:GetBasicType() .. " " ..type:GetDeclaration(meta_data) .. " " .. type.name .. " ; "
				else
					str = str .. type:GetDeclaration(meta_data) .. " " .. type.name .. " ; "
				end
			end
			str = str .. " }"

			return str
		end

		function STRUCT:FetchRequired(meta_data, out, temp)
			temp = temp or {}

			for _, type in ipairs(self.data) do
				type:FetchRequired(meta_data, out, temp)
			end
		end
	end

	do -- var arg
		local VARARG = metatables.var_arg

		function VARARG:Create()
			return {}
		end

		function VARARG:GetDeclaration()
			return "..."
		end

		function VARARG:GetCopy()
			return VARARG:Create()
		end

		function VARARG:GetBasicType()
			return "var_arg"
		end
	end
end

function ffibuild.BuildMinimalHeader(meta_data, check_function, check_enum, empty_structs)
	local required = {}
	local done = {}

	local bottom = ""

	for func_name, func_type in pairs(meta_data.functions) do
		if not check_function or check_function(func_name, func_type) then
			func_type:FetchRequired(meta_data, required, done)
			bottom = bottom .. func_type:GetDeclaration(meta_data) .. ";\n"
		end
	end

	local top = ""

	-- global enums
	if #meta_data.global_enums > 0 then
		for _, enums in ipairs(meta_data.global_enums) do
			local declaration = enums:GetDeclaration(meta_data, check_enum)
			if declaration then
				top = top .. declaration .. "\n"
			end
		end
	end

	-- typedef enums
	for _, type in ipairs(required) do
		if type:GetSubType() == "enum" then
			local enums = meta_data.enums[type:GetBasicType(meta_data)]

			local declaration = enums:GetDeclaration(meta_data, check_enum)
			if declaration then
				top = top .. declaration .. "\n"
			end
		end
	end

	-- structs and unions
	for _, type in ipairs(required) do
		local basic_type = type:GetBasicType(meta_data)

		if type:GetSubType() == "struct" then
			if not empty_structs and meta_data.structs[basic_type] then
				top = top .. basic_type .. " " .. meta_data.structs[basic_type]:GetPrimitive(meta_data):GetDeclaration(meta_data) .. ";\n"
			else
				top = top .. basic_type .. " { };\n"
			end
		elseif type:GetSubType() == "union" then
			if not empty_structs and meta_data.unions[basic_type] then
				top = top .. basic_type .. " " .. meta_data.unions[basic_type]:GetPrimitive(meta_data):GetDeclaration(meta_data) .. ";\n"
			else
				top = top .. basic_type .. " { };\n"
			end
		end
	end

	return top .. bottom
end

do -- lua helper functions

	ffibuild.helper_functions = {
		chars_to_string = [[
	local function chars_to_string(ctyp)
		if ctyp ~= nil then
			return ffi.string(ctyp)
		end
		return ""
	end]],

		metatables = [[
	local metatables = {}
	local object_cache = {}

	local function wrap_pointer(ptr, meta_name)
		-- TODO
		-- you should be able to use cdata as key and it would use the address
		-- but apparently that doesn't work
		local id = tostring(ptr)

		if not object_cache[meta_name] then
			object_cache[meta_name] = setmetatable({}, {__mode = "v"})
		end

		if not object_cache[meta_name][id] then
			object_cache[meta_name][id] = setmetatable({ptr = ptr}, metatables[meta_name])
		end

		return object_cache[meta_name][id]
	end]]
	}

	function ffibuild.BuildGenericLua(ffi_header, ffi_lib, ...)
		local lua =
		"local ffi = require(\"ffi\")\n" ..
		"ffi.cdef([["..ffi_header.."]])\n" ..
		"local CLIB = ffi.load(\""..ffi_lib.."\")\n" ..
		"local library = {}\n"

		if ... then
			for _, which in ipairs({...}) do
				if ffibuild.helper_functions[which] then
					lua = lua .. "\n\n--====helper " .. which .. "====\n"
					lua = lua .. ffibuild.helper_functions[which] .. "\n"
					lua = lua .. "--====helper " .. which .. "====\n\n"
				end
			end

		end

		return lua
	end

	function ffibuild.BuildLuaMetaTable(meta_name, declaration, functions, argument_translate, return_translate, meta_data)
		local lua = ""
		lua = lua .. "do\n"
		lua = lua .. "\tlocal META = {\n"
		lua = lua .. "\t\tctype = ffi.typeof(\"" .. declaration .. "\"),\n"
		for friendly_name, func_type in pairs(functions) do
			lua = lua .. "\t\t" .. ffibuild.BuildLuaFunction(friendly_name, func_type.name, func_type, argument_translate, return_translate, meta_data, true) .. ",\n"
		end
		lua = lua .. "\t}\n"
		lua = lua .. "\tMETA.__index = META\n"
		lua = lua .. "\tmetatables." .. meta_name .. " = META\n"
		lua = lua .. "end\n"
		return lua
	end

	function ffibuild.BuildLuaFunction(friendly_name, real_name, func_type, call_translate, return_translate, meta_data, first_argument_self, clib)
		clib = clib or "CLIB"

		local s = ""

		if call_translate or return_translate then
			local parameters, call = func_type:GetParameters(first_argument_self, call_translate and function(type, name)
				type = type:GetPrimitive(meta_data)

				return	call_translate(type:GetDeclaration(meta_data), name, type, func_type) or name
			end)


			s = s .. friendly_name .. " = function(" .. parameters .. ") "
			s = s .. "local v = " .. clib .. "." .. real_name .. "(" .. call .. ") "
		else
			s = s .. friendly_name .. " = " .. clib .. "." .. real_name
		end

		if return_translate then
			local return_type = func_type.return_type:GetPrimitive(meta_data) or func_type.return_type
			local declaration = return_type:GetDeclaration(meta_data)

			local ret, func = return_translate(declaration, return_type, func_type)

			s = s .. (ret or "")

			if func then
				s = func(s)
			end
		end

		if call_translate or return_translate then
			s = s .. " return v "
			s = s .. "end"
		end

		return s
	end

	function ffibuild.OutputAndValidate(lua, header)
		-- check if this wokrs if possible
		if jit and header then
			local ok, err = pcall(function()
				require("ffi").cdef(header)
			end)
			if not ok then
				print(err)
				local line = tonumber(err:match("line (%d+)"))
				local i = 1
				for s in header:gmatch("(.-)\n") do
					if line > i - 3 and line < i + 3 then
						print(i .. ": " .. s)
					end
					i = i + 1
				end
				return
			end
		end

		assert(loadstring(lua))

		io.write(lua) -- write output to make file
	end
end

return ffibuild