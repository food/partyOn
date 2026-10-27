-- Finds where the server keeps a connected player's PlayerId (the id marker rules carry).
-- Load as a temporary Windrose+ mod (init.lua: dofile of this file), then RCON `wp.idprobe`.
-- Scans every player state, its pawn, its owner (controller) and their components for strings
-- and GUIDs; values equal to a known PlayerId (markersync_players.txt) are marked with "<==".
local API = WindrosePlus.API
local DATA = "Z:/home/steam/server-files/windrose_plus_data/"
local OUT = DATA .. "idprobe.txt"

local function known_ids()
    local ids = {}
    local f = io.open(DATA .. "markersync_players.txt", "r")
    if f then
        for line in f:lines() do
            local id = line:match("^(%x+)")
            if id and #id == 32 then ids[id:upper()] = true end
        end
        f:close()
    end
    return ids
end

-- Every 32-hex string or FGuid (A, B, C, D) found in a value, with its path.
local function collect(v, path, depth, out)
    if depth > 3 then return end
    -- Struct values answer ToString with their type ("ScriptStruct /Script/..."), so those are
    -- walked field by field below instead.
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" and not s:match("^ScriptStruct ") then
        if #s >= 16 or path:match("Id[^.]*$") then out[#out + 1] = { path, s } end
        return
    end
    local okg, a, b, c, d = pcall(function() return v.A, v.B, v.C, v.D end)
    if okg and type(a) == "number" and type(d) == "number" then
        out[#out + 1] = { path, string.format("%08X%08X%08X%08X", a & 0xffffffff, b & 0xffffffff, c & 0xffffffff, d & 0xffffffff) }
        return
    end
    pcall(function()
        v:GetStruct():ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            collect(v[n], path .. "." .. n, depth + 1, out)
        end)
    end)
end

local function scan_object(o, label, out)
    if not o or not o:IsValid() then return end
    local cls = o:GetClass()
    while cls and cls:IsValid() do
        cls:ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            local ok, v = pcall(function() return o[n] end)
            if ok and v ~= nil and type(v) ~= "number" and type(v) ~= "boolean" then
                collect(v, label .. "." .. n, 0, out)
            end
        end)
        cls = cls:GetSuperStruct()
    end
end

local function components(actor)
    local list = {}
    pcall(function()
        actor:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent")):ForEach(function(_, c)
            list[#list + 1] = c:get()
        end)
    end)
    return list
end

API.registerCommand("wp.idprobe", function()
    local ids, lines = known_ids(), {}
    local gs = FindFirstOf("GameStateBase")
    gs.PlayerArray:ForEach(function(_, ref)
        local ps = ref:get()
        local name = "?"
        pcall(function() name = ps.PlayerNamePrivate:ToString() end)
        lines[#lines + 1] = "== " .. name .. " " .. ps:GetFullName()
        local out = {}
        local actors = { { ps, "ps" } }
        pcall(function() actors[#actors + 1] = { ps:GetPawn(), "pawn" } end)
        pcall(function() actors[#actors + 1] = { ps:GetOwner(), "owner" } end)
        for _, a in ipairs(actors) do
            scan_object(a[1], a[2], out)
            for _, c in ipairs(components(a[1])) do
                scan_object(c, a[2] .. ":" .. c:GetFName():ToString(), out)
            end
        end
        for _, e in ipairs(out) do
            local hit = ids[e[2]:upper():gsub("-", "")] and "  <==" or ""
            if hit ~= "" or e[2]:match("^[%x%-]+$") or e[1]:match("Id[^.]*$") then
                lines[#lines + 1] = string.format("  %s = %s%s", e[1], e[2]:sub(1, 80), hit)
            end
        end
    end)
    local f = io.open(OUT, "w")
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    return #lines .. " lines written to idprobe.txt"
end, "Find the PlayerId of connected players", "wp.idprobe")
