-- P3 spike: watch death and revive on the server and try the knobs a revive mod would need.
--   wp.rev classes          properties and functions of the revive/death classes (to the log)
--   wp.rev info             property values of every revive/death component and its settings object
--   wp.rev set <prop> <v>   set a number/enum property wherever it exists on those objects
-- Every UFunction call on R5ReviveComponent / R5DeathComponent and every ServerExecRPC message
-- is logged with a timestamp.
local API = WindrosePlus.API
local LOG = "Z:/home/steam/server-files/windrose_plus_data/partyrevive.log"
local CLASSES = {
    "/Script/R5.R5ReviveComponent", "/Script/R5.R5DeathComponent",
    "/Script/R5.R5ReviveData", "/Script/R5.R5PersonalDeathData", "/Script/R5.R5BaseActorDeathData",
}

local logf = io.open(LOG, "a")
local function log(fmt, ...)
    logf:write(os.date("!%H:%M:%S "), string.format(fmt, ...), "\n")
    logf:flush()
end

local function propdesc(p)
    local t = p:GetClass():GetFName():ToString()
    local extra = ""
    if t == "StructProperty" then
        local ok, s = pcall(function() return p:GetStruct():GetFName():ToString() end)
        if ok then extra = "<" .. s .. ">" end
    elseif t == "ObjectProperty" or t == "ClassProperty" then
        local ok, c = pcall(function() return p:GetPropertyClass():GetFName():ToString() end)
        if ok then extra = "<" .. c .. ">" end
    end
    return p:GetFName():ToString() .. ":" .. t .. extra
end

local function value(v, depth)
    local t = type(v)
    if t ~= "userdata" then return tostring(v) end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and s then return s end
    local parts = {}
    local ok2 = pcall(function()
        v:GetStruct():ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            parts[#parts + 1] = n .. "=" .. ((depth or 0) < 2 and value(v[n], (depth or 0) + 1) or "?")
        end)
    end)
    if ok2 and #parts > 0 then return "{" .. table.concat(parts, ", ") .. "}" end
    local ok3, name = pcall(function() return v:GetFullName() end)
    return ok3 and name or tostring(v)
end

local function dump_object(o)
    local out = { o:GetFullName() }
    local cls = o:GetClass()
    while cls and cls:IsValid() and cls:GetFullName():find("/Script/R5", 1, true) do
        cls:ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            local ok, v = pcall(function() return o[n] end)
            out[#out + 1] = "  " .. propdesc(p) .. " = " .. (ok and value(v) or "<err>")
        end)
        cls = cls:GetSuperStruct()
    end
    for _, fn in ipairs({ "IsReviveInProgress", "GetReviveTime" }) do
        local ok, r = pcall(function() return o[fn](o) end)
        if ok and r ~= nil then out[#out + 1] = "  " .. fn .. "() = " .. tostring(r) end
    end
    return table.concat(out, "\n")
end

local ops = {}

function ops.classes()
    for _, path in ipairs(CLASSES) do
        local cls = StaticFindObject(path)
        if cls and cls:IsValid() then
            log("== %s", path)
            pcall(function()
                cls:ForEachFunction(function(fn)
                    local params = {}
                    fn:ForEachProperty(function(p) params[#params + 1] = propdesc(p) end)
                    log("  fn %s flags=0x%08x (%s)", fn:GetFName():ToString(), fn:GetFunctionFlags(), table.concat(params, ", "))
                end)
            end)
            cls:ForEachProperty(function(p) log("  prop %s", propdesc(p)) end)
        else
            log("== %s not found", path)
        end
    end
    return "written to partyrevive.log"
end

-- Objects a revive mod would touch: each component plus the settings objects it points to.
local function targets()
    local out = {}
    for _, c in ipairs(FindAllOf("R5ReviveComponent") or {}) do
        out[#out + 1] = c
        local ok, s = pcall(function() return c.ReviveSettings end)
        if ok and s and s:IsValid() then out[#out + 1] = s end
    end
    for _, c in ipairs(FindAllOf("R5DeathComponent") or {}) do
        out[#out + 1] = c
        local ok, s = pcall(function() return c.DeathParams end)
        if ok and s and s:IsValid() then out[#out + 1] = s end
    end
    return out
end

function ops.info()
    local seen, n = {}, 0
    for _, o in ipairs(targets()) do
        local name = o:GetFullName()
        if not seen[name] then
            seen[name] = true
            log("%s", dump_object(o))
            n = n + 1
        end
    end
    return n .. " object(s) written to partyrevive.log"
end

-- wp.rev set <prop> <number>: on every target object that has the property (settings objects
-- are shared defaults, so a change there affects every player).
function ops.set(a)
    local prop, v = a[2], tonumber(a[3])
    if not prop or not v then return "usage: wp.rev set <prop> <number>" end
    local done = {}
    for _, o in ipairs(targets()) do
        local name = o:GetFullName()
        local has = pcall(function() return o[prop] end) and o[prop] ~= nil
        if has and not done[name] then
            done[name] = true
            local ok, err = pcall(function() o[prop] = v end)
            log("set %s.%s = %s -> %s %s", name, prop, tostring(v), tostring(ok), tostring(err or ""))
        end
    end
    local n = 0
    for _ in pairs(done) do n = n + 1 end
    return "set on " .. n .. " object(s)"
end

-- Hook every UFunction of the two component classes; getters are skipped to keep the log readable.
for _, path in ipairs({ "/Script/R5.R5ReviveComponent", "/Script/R5.R5DeathComponent" }) do
    local cls = StaticFindObject(path)
    if cls and cls:IsValid() then
        cls:ForEachFunction(function(fn)
            local name = fn:GetFName():ToString()
            if not name:match("^Get") and not name:match("^Is") then
                local ok, err = pcall(function()
                    RegisterHook(path .. ":" .. name, function(self)
                        local who = "?"
                        pcall(function() who = self:get():GetOwner():GetFullName() end)
                        log("call %s.%s on %s", path:match("[^.]+$"), name, who)
                    end)
                end)
                if not ok then log("hook %s failed: %s", name, tostring(err)) end
            end
        end)
    end
end

RegisterHook("/Script/Engine.PlayerController:ServerExecRPC", function(self, msg)
    local who, text = "?", "?"
    pcall(function() who = self:get().PlayerState.PlayerNamePrivate:ToString() end)
    pcall(function() text = msg:get():ToString() end)
    log("ServerExecRPC from %s: %s", who, text)
end)

API.registerCommand("wp.rev", function(args)
    local op = ops[args[1] or ""]
    if not op then return "usage: wp.rev classes|info|set <prop> <number>" end
    local ok, res = pcall(op, args)
    return ok and tostring(res) or ("failed: " .. tostring(res))
end, "Revive spike", "wp.rev classes|info|set")

log("partyrevive spike loaded")
