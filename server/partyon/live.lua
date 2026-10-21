-- Live markers: the DLL writes one line per marker action of a player to markersync_events.txt.
-- For every other online player we create, move, rename or destroy a server-side marker model
-- on their R5MarkersSystemComponent. Those models replicate to their owner and show up at once.
-- The DLL's rule replay keeps the save in sync, so after a relog the marker comes from the save.
--
-- The live copy is a Simple marker model, not a User one: R5MarkerModelBase does not replicate
-- MarkerType (the user marker's icon index), R5MarkerModelSimple replicates its Icon texture.
-- The texture is taken from the user marker class's own icon list, Icons[type].
--
-- Line: A|U <tab> sender <tab> markerId <tab> x <tab> y <tab> z <tab> type <tab> localized <tab> snap <tab> name
--       R   <tab> sender <tab> markerId
-- snap is bSnappingAllowed, the "far away" option that keeps the marker on the minimap edge.
-- sender is the AccountId of the player who set the marker. For a rule sent through another
-- player's connection (the test bot) it is the PlayerId, so every real player gets a copy.
local API = WindrosePlus.API
local EVENTS = "Z:/home/steam/server-files/windrose_plus_data/markersync_events.txt"
local USER = "/Game/UI/HUD/Navigation/MarkerModels/BP_MarkerModel_User"
local SIMPLE = "/Game/UI/HUD/Navigation/MarkerModels/BP_MarkerModel_Simple"

local offset = 0
do  -- skip events from before a Lua reload, they were already applied
    local f = io.open(EVENTS, "r")
    if f then offset = f:seek("end"); f:close() end
end

local models = {}    -- models[account][markerId] = marker model
local sessions = {}  -- sessions[account] = { comp = address, since = time the player state appeared }
local born = {}      -- born[markerId] = time we first saw the marker added

local function class_of(asset)
    local path = asset .. "." .. asset:match("[^/]+$") .. "_C"
    local cls = StaticFindObject(path)
    if not cls or not cls:IsValid() then
        pcall(LoadAsset, asset)
        cls = StaticFindObject(path)
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

-- GUID of a live copy: the marker's id with the last part flipped. It must differ from the real
-- marker's id. Destroying a copy runs the remove rule for its GUID on the recipient's record, and
-- the client removes by GUID too, so a shared id deleted the real marker along with the copy.
local function copy_guid(hex)
    local function part(i) return tonumber(hex:sub(i, i + 7), 16) end
    return { A = part(1), B = part(9), C = part(17), D = part(25) ~ 0x5A5A5A5A }
end

-- Self-test (flag file markersync_selftest_live): the sender also gets a live copy 20 m east.
local function selftest()
    local f = io.open("Z:/home/steam/server-files/windrose_plus_data/markersync_selftest_live", "r")
    if f then f:close() return true end
    return false
end

-- Remembers when a player's state appeared; a new state means the player (re)joined.
local function session_since(acct, comp)
    local addr = comp:GetAddress()
    local s = sessions[acct]
    if not s or s.comp ~= addr then
        s = { comp = addr, since = os.time() }
        sessions[acct] = s
        models[acct] = {}
    end
    return s.since
end

-- Builds a copy. CreateMarker with an empty OwnerId makes the game save the model as a user
-- marker of the recipient (a nameless ghost after relog); an owner marks it as a system marker.
local function create_copy(comp, simple, user, ev, pos)
    local m = comp:CreateMarker(simple, pos, { ID = ev.sender })
    pcall(function() m.MarkerGuid = copy_guid(ev.id) end)
    -- Same visibility as a real user marker, so the copy also shows in the world view.
    local cdo = user:GetCDO()
    for _, f in ipairs({ "WorldVisibilityData", "MapVisibilityData", "MiniMapVisibilityData",
                         "TagsVisibilityData", "OptionalWorldSize" }) do
        pcall(function() m[f] = cdo[f] end)
    end
    pcall(function() m.bSnappingAllowed = ev.snap end)
    return m
end

-- Sets icon, name and position of a copy; Simple models replicate all three.
local function update_copy(m, user, ev, pos)
    m.Location = pos
    pcall(function() m.Icon = user:GetCDO().Icons[(ev.type or 0) + 1] end)
    -- A fresh marker carries a localized default name key; show the German default instead.
    pcall(function() m:SetShownName(FText(ev.localized and "Neue Markierung" or ev.name)) end)
    pcall(function() m:Update() end)
end

-- DestroyMarker on the component is what replicates the removal to the client; the model's
-- own RemoveMarker only detached it on the server and the copy stayed visible.
local function remove_copy(comp, m)
    pcall(function() comp:DestroyMarker(m) end)
end

local function apply(ev)
    local simple, user = class_of(SIMPLE), class_of(USER)
    if not simple or not user then API.log("warn", "markersync", "marker classes not found"); return end
    if ev.op == "A" and not born[ev.id] then born[ev.id] = os.time() end
    local self_copy = selftest()
    for acct, comp in pairs(marker_systems()) do
        if acct ~= ev.sender or self_copy then
            local since = session_since(acct, comp)
            local m = models[acct][ev.id]
            local valid = m and m:IsValid()
            if ev.op == "R" then
                if valid then remove_copy(comp, m) end
                models[acct][ev.id] = nil
            elseif (born[ev.id] or 0) >= since then
                -- Markers older than this player's login came with the save; a copy would double them.
                local pos = { X = ev.x + (acct == ev.sender and 2000 or 0), Y = ev.y, Z = ev.z }
                local name = ev.localized and "Neue Markierung" or ev.name
                if valid then
                    -- Location and Icon replicate on change, ShownName only with the first replication.
                    -- bSnappingAllowed is treated the same way until it is known to replicate on change.
                    local ok, cur = pcall(function() return m.ShownName:ToString() end)
                    local okS, snap = pcall(function() return m.bSnappingAllowed end)
                    if not ok or cur ~= name or (okS and type(snap) == "boolean" and snap ~= ev.snap) then
                        remove_copy(comp, m)
                        valid = false
                    end
                end
                if not valid then
                    m = create_copy(comp, simple, user, ev, pos)
                    models[acct][ev.id] = m
                end
                update_copy(m, user, ev, pos)
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
        if #f < 10 then return nil end
        ev.x, ev.y, ev.z, ev.type = tonumber(f[4]), tonumber(f[5]), tonumber(f[6]), tonumber(f[7])
        ev.localized, ev.snap, ev.name = f[8] == "1", f[9] == "1", f[10]
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
    for line in data:gmatch("([^\n]*)\n") do
        consumed = consumed + #line + 1
        local ev = parse(line)
        if ev then
            local ok, err = pcall(apply, ev)
            if not ok then API.log("warn", "markersync", "live marker failed: " .. tostring(err)) end
        end
    end
    offset = offset + consumed  -- a half-written last line is read next time
end

-- UObjects may only be touched on the game thread. ExecuteInGameThread does not work here
-- (Windrose+ must run with HookEngineTick=0), so we piggyback on client RPCs the server runs on
-- the game thread: ServerMovePacked while a player moves, ServerUpdateCamera while one looks around.
-- Do not hot-reload this mod: a reload with these hooks active takes the server down. Restart instead.
local polls, last = 0, 0
local function tick()
    local now = os.clock()
    if now - last < 0.25 then return end
    last = now
    polls = polls + 1
    local ok, err = pcall(poll)
    if not ok then API.log("warn", "markersync", "poll failed: " .. tostring(err)) end
end
RegisterHook("/Script/Engine.Character:ServerMovePacked", tick)
RegisterHook("/Script/Engine.PlayerController:ServerUpdateCamera", tick)
API.log("info", "markersync", "live markers active")

API.registerCommand("wp.msync", function(args)
    local out = { string.format("offset=%d polls=%d", offset, polls) }
    for acct, list in pairs(models) do
        for id, m in pairs(list) do
            local okN, name = pcall(function() return m.ShownName:ToString() end)
            out[#out + 1] = string.format("  %s %s valid=%s name=%s", acct:sub(1, 8), id:sub(1, 8),
                tostring(m:IsValid()), okN and name or "?")
        end
    end
    return table.concat(out, "\n")
end, "markersync live status", "wp.msync")
