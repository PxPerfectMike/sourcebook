-- Tiny test library: T(name, fn) registers a test; eq, ok and fails assert.

local tests = {}

function T(name, fn)
	tests[#tests + 1] = { name = name, fn = fn }
end

local function show(v, depth)
	depth = depth or 0
	if type(v) == "string" then
		return string.format("%q", v)
	end
	if type(v) ~= "table" then
		return tostring(v)
	end
	if depth > 3 then
		return "{...}"
	end
	local keys = {}
	for k in pairs(v) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = "[" .. show(k) .. "]=" .. show(v[k], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function same(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function eq(a, b, msg)
	if not same(a, b) then
		error((msg and msg .. ": " or "") .. "expected " .. show(b) .. ", got " .. show(a), 2)
	end
end

function ok(v, msg)
	if not v then
		error(msg or "expected a true value", 2)
	end
end

function fails(fn, pattern)
	local good, err = pcall(fn)
	if good then
		error("expected an error", 2)
	end
	if pattern and not tostring(err):find(pattern) then
		error("error did not match " .. pattern .. ": " .. tostring(err), 2)
	end
end

function RunTests()
	local passed, failed = 0, 0
	for _, t in ipairs(tests) do
		local good, err = pcall(t.fn)
		if good then
			passed = passed + 1
			print("PASS " .. t.name)
		else
			failed = failed + 1
			print("FAIL " .. t.name .. ": " .. tostring(err))
		end
	end
	tests = {}
	return passed, failed
end
