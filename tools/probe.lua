-- Reverse-engineering helper, not loaded in production (copy next to init.lua and dofile it).
-- wp.uprobe <ClassPath> lists UFunctions with flags and params; wp.rpcs, wp.mktest, wp.pstate, wp.acct.
local API = WindrosePlus.API

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

API.registerCommand("wp.uprobe", function(args)
    local cls = StaticFindObject(args[1] or "")
    if not cls or not cls:IsValid() then return "class not found: " .. tostring(args[1]) end
    local out = {}
    cls:ForEachFunction(function(fn)
        local params = {}
        fn:ForEachProperty(function(p) params[#params + 1] = propdesc(p) end)
        out[#out + 1] = string.format("%s flags=0x%08x (%s)", fn:GetFName():ToString(), fn:GetFunctionFlags(),
            table.concat(params, ", "))
    end)
    out[#out + 1] = "-- properties:"
    cls:ForEachProperty(function(p) out[#out + 1] = "  " .. propdesc(p) end)
    return table.concat(out, "\n")
end, "List UFunctions with flags and params", "wp.uprobe /Script/R5.SomeClass")

-- wp.rpcs [filter]: every NetClient / NetMulticast UFunction of /Script/R5 and /Game classes, written to a file.
API.registerCommand("wp.rpcs", function(args)
    local filter = args[1] and args[1]:lower()
    local lines, n = {}, 0
    ForEachUObject(function(obj)
        if obj:IsA("/Script/CoreUObject.Class") then
            local path = obj:GetFullName()
            if path:find("/Script/R5", 1, true) or path:find("/Game/", 1, true) then
                obj:ForEachFunction(function(fn)
                    local fl = fn:GetFunctionFlags()
                    local client, multi = (fl & 0x01000000) ~= 0, (fl & 0x00004000) ~= 0
                    if client or multi then
                        local params = {}
                        fn:ForEachProperty(function(p) params[#params + 1] = propdesc(p) end)
                        local line = string.format("%s %s::%s(%s)", client and "CLIENT" or "MULTI",
                            obj:GetFName():ToString(), fn:GetFName():ToString(), table.concat(params, ", "))
                        if not filter or line:lower():find(filter, 1, true) then
                            lines[#lines + 1] = line; n = n + 1
                        end
                    end
                end)
            end
        end
    end)
    table.sort(lines)
    local f = io.open("Z:/home/steam/server-files/windrose_plus_data/rpcs.txt", "w")
    f:write(table.concat(lines, "\n")); f:close()
    return n .. " rpcs written to windrose_plus_data/rpcs.txt"
end, "List client/multicast RPCs", "wp.rpcs [filter]")

-- wp.mktest [dx]: server-side CreateMarker on every player's R5MarkersSystemComponent, dx cm east of player 1.
API.registerCommand("wp.mktest", function(args)
    local out = {}
    local cls = StaticFindObject("/Game/UI/HUD/Navigation/MarkerModels/BP_MarkerModel_User.BP_MarkerModel_User_C")
    if not cls or not cls:IsValid() then
        local ok = pcall(function() LoadAsset("/Game/UI/HUD/Navigation/MarkerModels/BP_MarkerModel_User") end)
        cls = StaticFindObject("/Game/UI/HUD/Navigation/MarkerModels/BP_MarkerModel_User.BP_MarkerModel_User_C")
        out[#out + 1] = "class loaded via LoadAsset: " .. tostring(ok)
    end
    if not cls or not cls:IsValid() then return "marker class not found" end
    local p = API.getPlayers()[1]
    if not p then return "no player online" end
    local pos = { X = p.x + (tonumber(args[1]) or 2000), Y = p.y, Z = p.z }
    local comps = FindAllOf("R5MarkersSystemComponent") or {}
    for _, c in ipairs(comps) do
        local ok, res = pcall(function()
            local m = c:CreateMarker(cls, pos, {})
            if args[2] and m and m:IsValid() then m:SetShownName(FText(args[2])) end
            return m
        end)
        out[#out + 1] = string.format("%s -> ok=%s res=%s", c:GetFullName(), tostring(ok),
            ok and res and res.IsValid and res:IsValid() and res:GetFullName() or tostring(res))
    end
    out[#out + 1] = string.format("pos %.0f %.0f %.0f, %d component(s)", pos.X, pos.Y, pos.Z, #comps)
    return table.concat(out, "\n")
end, "Server-side CreateMarker test", "wp.mktest [dx] [name]")

-- wp.pstate: R5BLRecordId / string-ish properties of every player state (and its components' owners).
local function dumpval(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and s then return s end
        local parts = {}
        local ok2 = pcall(function()
            v:GetStruct():ForEachProperty(function(p)
                local n = p:GetFName():ToString()
                parts[#parts + 1] = n .. "=" .. (depth < 2 and dumpval(v[n], depth + 1) or "?")
            end)
        end)
        if ok2 and #parts > 0 then return "{" .. table.concat(parts, ",") .. "}" end
        return tostring(v)
    end
    return tostring(v)
end

API.registerCommand("wp.pstate", function(args)
    local out = {}
    for _, ps in ipairs(FindAllOf("R5PlayerState") or {}) do
        out[#out + 1] = ps:GetFullName()
        local cls = ps:GetClass()
        while cls and cls:IsValid() do
            cls:ForEachProperty(function(p)
                local d = propdesc(p)
                if d:find("RecordId") or d:find("StrProperty") or d:find("Id:") or d:find("Account") or d:find("Player") then
                    local ok, v = pcall(function() return ps[p:GetFName():ToString()] end)
                    out[#out + 1] = "  " .. d .. " = " .. (ok and dumpval(v) or "<err>")
                end
            end)
            cls = cls:GetSuperStruct()
        end
    end
    return table.concat(out, "\n")
end, "Dump id-like properties of player states", "wp.pstate")

-- wp.acct: fields of PlayerState.AccountData, nested structs one level deep.
local function structdump(val, sdef, depth)
    local parts = {}
    sdef:ForEachProperty(function(p)
        local n, t = p:GetFName():ToString(), p:GetClass():GetFName():ToString()
        local ok, v = pcall(function() return val[n] end)
        local s
        if not ok then s = "<err>"
        elseif t == "StructProperty" and depth < 3 then s = structdump(v, p:GetStruct(), depth + 1)
        elseif t == "StrProperty" or t == "NameProperty" or t == "TextProperty" then
            local ok2, r = pcall(function() return v:ToString() end); s = ok2 and ('"' .. r .. '"') or tostring(v)
        else s = tostring(v) end
        parts[#parts + 1] = n .. "=" .. s
    end)
    return "{" .. table.concat(parts, ", ") .. "}"
end

API.registerCommand("wp.acct", function(args)
    local out = {}
    for _, ps in ipairs(FindAllOf("R5PlayerState") or {}) do
        local prop, cls = nil, ps:GetClass()
        while not prop and cls and cls:IsValid() do
            cls:ForEachProperty(function(p) if p:GetFName():ToString() == "AccountData" then prop = p end end)
            cls = cls:GetSuperStruct()
        end
        out[#out + 1] = ps:GetFullName() .. " " .. ps.PlayerNamePrivate:ToString()
        out[#out + 1] = "  " .. (prop and structdump(ps.AccountData, prop:GetStruct(), 0) or "no AccountData prop")
    end
    return table.concat(out, "\n")
end, "Dump PlayerState.AccountData", "wp.acct")
