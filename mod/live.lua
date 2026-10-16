-- Live markers: the DLL writes one line per marker action of a player to markersync_events.txt.
-- For every other online player we create, move, rename or destroy a server-side marker model
-- on their R5MarkersSystemComponent. Those models replicate to the client and show up at once.
-- The DLL's rule replay keeps the save in sync, so after a relog the marker comes from the save.
--
-- Line: A|U <tab> senderAccount <tab> markerId <tab> x <tab> y <tab> z <tab> type <tab> localized <tab> name
--       R   <tab> senderAccount <tab> markerId
local API = WindrosePlus.API
local EVENTS = "Z:/home/steam/server-files/windrose_plus_data/markersync_events.txt"
local CLASS = "/Game/UI/HUD/Navigation/MarkerModels/BP_MarkerModel_User.BP_MarkerModel_User_C"

local offset = 0
do  -- skip events from before a Lua reload, they were already applied
    local f = io.open(EVENTS, "r")
    if f then offset = f:seek("end"); f:close() end
end

local models = {}  -- models[account][markerId] = marker model

local function marker_class()
    local cls = StaticFindObject(CLASS)
    if not cls or not cls:IsValid() then
        pcall(LoadAsset, "/Game/UI/HUD/Navigation/MarkerModels/BP_MarkerModel_User")
        cls = StaticFindObject(CLASS)
    end
    return cls and cls:IsValid() and cls or nil
end

-- account -> R5MarkersSystemComponent of that player's state
local function marker_systems()
    local res = {}
    for _, c in ipairs(FindAllOf("R5MarkersSystemComponent") or {}) do
        local ok, acct = pcall(function() return c:GetOuter().AccountData.AccountId.ID:ToString() end)
        if ok and acct and acct ~= "" then res[acct] = c end
    end
    return res
end

local function guid(hex)
    local function part(i) return tonumber(hex:sub(i, i + 7), 16) end
    return { A = part(1), B = part(9), C = part(17), D = part(25) }
end

local function apply(ev)
    local systems = marker_systems()
    for acct, comp in pairs(systems) do
        if acct ~= ev.sender then
            models[acct] = models[acct] or {}
            local m = models[acct][ev.id]
            local valid = m and m:IsValid()
            if ev.op == "R" then
                if valid then pcall(function() comp:DestroyMarker(m) end) end
                models[acct][ev.id] = nil
            else
                local pos = { X = ev.x, Y = ev.y, Z = ev.z }
                if not valid then
                    local cls = marker_class()
                    if not cls then API.log("warn", "markersync", "marker class not found"); return end
                    m = comp:CreateMarker(cls, pos, {})
                    models[acct][ev.id] = m
                    pcall(function() m.MarkerGuid = guid(ev.id) end)
                else
                    m.Location = pos
                end
                -- A fresh marker carries a localized default name key; show a plain word instead.
                pcall(function() m:SetShownName(FText(ev.localized and "Marker" or ev.name)) end)
                pcall(function() m:SetIcon(ev.type) end)
                pcall(function() m:Update() end)
            end
        end
    end
end

local function parse(line)
    local f = {}
    for v in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
    if #f < 3 then return nil end
    local ev = { op = f[1], sender = f[2], id = f[3] }
    if ev.op ~= "R" then
        if #f < 9 then return nil end
        ev.x, ev.y, ev.z, ev.type = tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
        ev.localized, ev.name = f[8] == "1", f[9]
    end
    return ev
end

local function poll()
    local f = io.open(EVENTS, "r")
    if not f then return end
    local size = f:seek("end")
    if size < offset then offset = 0 end  -- DLL truncated the file on server start
    if size == offset then f:close(); return end
    f:seek("set", offset)
    local data = f:read("a")
    f:close()
    local consumed = 0
    for line, nl in data:gmatch("([^\n]*)(\n)") do
        consumed = consumed + #line + 1
        local ev = parse(line)
        if ev then
            local ok, err = pcall(apply, ev)
            if not ok then API.log("warn", "markersync", "live marker failed: " .. tostring(err)) end
        end
    end
    offset = offset + consumed  -- a half-written last line is read next time
end

-- ExecuteInGameThread never drains here (Windrose+ runs with HookEngineTick=0), so poll runs
-- straight from the async loop, the same way Windrose+ runs its own UObject writers and RCON commands.
local busy = false
LoopAsync(300, function()
    if not busy then
        busy = true
        local ok, err = pcall(poll)
        if not ok then API.log("warn", "markersync", "poll failed: " .. tostring(err)) end
        busy = false
    end
    return false
end)
API.log("info", "markersync", "live markers active")

local polls = 0
local _poll = poll
poll = function() polls = polls + 1; return _poll() end

API.registerCommand("wp.msync", function(args)
    local out = { string.format("offset=%d busy=%s polls=%d", offset, tostring(busy), polls) }
    for acct, c in pairs(marker_systems()) do
        local n = 0
        for _ in pairs(models[acct] or {}) do n = n + 1 end
        out[#out + 1] = string.format("  %s -> %s (%d models)", acct, c:GetFullName(), n)
    end
    if args[1] == "poll" then
        local ok, err = pcall(_poll)
        out[#out + 1] = "manual poll: " .. tostring(ok) .. " " .. tostring(err) .. " offset now " .. offset
    end
    return table.concat(out, "\n")
end, "markersync live status", "wp.msync [poll]")
