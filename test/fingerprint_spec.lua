local function equal(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

-- The original fingerprint algorithm (Data/Store.lua at ec6c858), kept here
-- verbatim as an oracle. Stored records and the bridge compare fingerprints
-- across addon versions, so the optimized implementation must match it byte
-- for byte.
local IGNORED = { capturedAt = true, reason = true }

local function appendStable(parts, value, ignoredKeys, depth)
    local valueType = type(value)
    if depth > 24 then
        table.insert(parts, "<depth>")
        return
    end
    if valueType ~= "table" then
        table.insert(parts, valueType)
        table.insert(parts, ":")
        table.insert(parts, tostring(value))
        table.insert(parts, ";")
        return
    end
    local keys = {}
    for key in pairs(value) do
        if not ignoredKeys or not ignoredKeys[key] then
            table.insert(keys, key)
        end
    end
    table.sort(keys, function(left, right)
        local leftType = type(left)
        local rightType = type(right)
        if leftType == rightType then
            return tostring(left) < tostring(right)
        end
        return leftType < rightType
    end)
    table.insert(parts, "{")
    for _, key in ipairs(keys) do
        appendStable(parts, key, nil, depth + 1)
        appendStable(parts, value[key], ignoredKeys, depth + 1)
    end
    table.insert(parts, "}")
end

local function oracle(value)
    local parts = {}
    appendStable(parts, value, IGNORED, 0)
    local serialized = table.concat(parts)
    local hash = 5381
    for index = 1, #serialized do
        hash = (hash * 33 + string.byte(serialized, index)) % 4294967296
    end
    return string.format("%08x", hash)
end

GuildweaverDB = nil
GetServerTime = function() return 1791322510 end
local addon = { version = "test" }
assert(loadfile("Data/Store.lua"))("Guildweaver", addon)
addon.Store.Initialize()
local fingerprint = addon.Store.Fingerprint

-- Deterministic pseudo-random payloads covering arrays, sparse arrays, mixed
-- key types, booleans, floats, negative numbers, long strings, nesting,
-- ignored keys and the depth limit.
local seed = 12345
local function random(limit)
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed % limit
end

local WORDS = { "name", "itemId", "tooltip", "lines", "left", "right", "capturedAt", "reason", "Ü", "a b", "10", "2" }

local function build(depth)
    local kind = random(depth > 4 and 4 or 7)
    if kind == 0 then return random(100000) - 50000 end
    if kind == 1 then return random(1000) / 7 end
    if kind == 2 then return random(2) == 1 end
    if kind == 3 then
        local length = random(40)
        local chars = {}
        for index = 1, length do
            chars[index] = string.char(32 + random(95))
        end
        return table.concat(chars)
    end
    local result = {}
    local count = random(12)
    for index = 1, count do
        local keyKind = random(4)
        if keyKind == 0 then
            result[index] = build(depth + 1)
        elseif keyKind == 1 then
            result[random(30) + 1] = build(depth + 1)
        elseif keyKind == 2 then
            result[WORDS[random(#WORDS) + 1]] = build(depth + 1)
        else
            result[random(2) == 1] = build(depth + 1)
        end
    end
    return result
end

for case = 1, 400 do
    local value = build(0)
    equal(fingerprint(value), oracle(value), "random payload " .. case)
end

-- Hand-picked edge cases.
local deep = {}
local cursor = deep
for _ = 1, 40 do
    cursor.next = { value = 1 }
    cursor = cursor.next
end
local deepArray = {}
cursor = deepArray
for _ = 1, 40 do
    cursor[1] = { 7 }
    cursor = cursor[1]
end
local cases = {
    deepArray,
    {},
    { 1, 2, 3, 10, 11, 20 },
    { [1] = "a", [2] = "b", [10] = "c", name = "x", [true] = false },
    { capturedAt = 1, reason = "x", nested = { capturedAt = 2, value = 3 } },
    { long = string.rep("abcdefghij", 5000) },
    { [123456789012345] = "wide integer key", [99999999999999] = "largest fast key", [-7] = "negative", [0] = "zero" },
    { [1.5] = "float key", [2] = "integer key" },
    { [true] = 1, [false] = 2 },
    deep,
    "plain string",
    42,
}
for index, value in ipairs(cases) do
    equal(fingerprint(value), oracle(value), "edge case " .. index)
end

-- Odd tail lengths exercise the 8-byte unrolled hash and its remainder.
for length = 0, 40 do
    local value = { text = string.rep("q", length) }
    equal(fingerprint(value), oracle(value), "tail length " .. length)
end

-- The resumable fingerprint (used to spread large payloads across frames)
-- matches too, whatever the chunk size.
local function resumable(value, chunk)
    local state = addon.Store.BeginFingerprint(value)
    local steps = 0
    while true do
        steps = steps + 1
        local done, result = addon.Store.StepFingerprint(state, chunk)
        if done then
            return result, steps
        end
    end
end

for case = 1, 200 do
    local value = build(0)
    local chunk = 1 + random(40)
    equal(resumable(value, chunk), oracle(value), "resumable random payload " .. case)
end
for index, value in ipairs(cases) do
    equal(resumable(value, 3), oracle(value), "resumable edge case " .. index)
end
local big = {}
for index = 1, 600 do
    big[index] = { recipeId = index, name = "Recipe " .. index, reagents = { { itemId = index, quantity = 2 } } }
end
local result, steps = resumable({ recipes = big }, 256)
equal(result, oracle({ recipes = big }), "resumable large payload")
equal(steps > 10, true, "large payload spread over many steps")

print("fingerprint_spec passed")
