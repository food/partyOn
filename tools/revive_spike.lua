-- P3 spike: watch death and revive on the server and try the knobs a revive mod would need.
--   wp.rev classes          properties and functions of the revive/death classes (to the log)
--   wp.rev info             property values of every revive/death component and its settings object
--   wp.rev set <prop> <v>   set a number/enum property wherever it exists on those objects
--   wp.rev ghost [name] [h] move the player's pawn h cm (default 1500) above where he last died,
--                           hide and freeze it
--   wp.rev unghost [name] [back]  undo; "back" returns to where the pawn was before ghost
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

-- Ghost test: the game's revive stays untouched, the new pawn is moved back to where the old
-- one died and made hidden, frozen and immune; unghost undoes it, optionally moving it back.
local DEATHS = "Z:/home/steam/server-files/windrose_plus_data/partyrevive_deaths.txt"
local deaths = {}   -- [player name] = death location, kept in DEATHS across restarts
local ghosts = {}   -- [player name] = respawn location

local existing = io.open(DEATHS)
if existing then
    existing:close()
    for line in io.lines(DEATHS) do
        local x, y, z, name = line:match("^(%S+) (%S+) (%S+) (.+)$")
        if name then deaths[name] = { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) } end
    end
end

local function save_deaths()
    local f = io.open(DEATHS, "w")
    for name, l in pairs(deaths) do f:write(string.format("%.1f %.1f %.1f %s\n", l.X, l.Y, l.Z, name)) end
    f:close()
end

local function player_pawn(name)
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local ok, n = pcall(function() return pc.PlayerState.PlayerNamePrivate:ToString() end)
        if ok and n == name and pc.Pawn:IsValid() then return pc.Pawn, pc end
    end
end

local function first_player()
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        local ok, n = pcall(function() return pc.PlayerState.PlayerNamePrivate:ToString() end)
        if ok then return n end
    end
end

local function set_ghost(pawn, on)
    local steps = {
        { "hidden", function() pawn:SetActorHiddenInGame(on) end },
        { "collision", function() pawn:SetActorEnableCollision(not on) end },
        { "damage", function() pawn.bCanBeDamaged = not on end },
        { "movement", function()
            if on then pawn.CharacterMovement:DisableMovement() else pawn.CharacterMovement:SetMovementMode(1, 0) end
        end },
    }
    local out = {}
    for _, s in ipairs(steps) do
        local ok, err = pcall(s[2])
        out[#out + 1] = s[1] .. "=" .. (ok and "ok" or tostring(err))
    end
    return table.concat(out, " ")
end

-- Pawn changes must run on the game thread; like windrose-testbot, the work is queued and run
-- from client RPC hooks (Windrose+ has HookEngineTick=0).
local queue = {}
local game = {}

local function tick()
    if #queue == 0 then return end
    local job = table.remove(queue, 1)
    local ok, res = pcall(game[job[1]], job)
    log("run %s -> %s", table.concat(job, " "), ok and tostring(res) or ("failed: " .. tostring(res)))
end
RegisterHook("/Script/Engine.Character:ServerMovePacked", tick)
RegisterHook("/Script/Engine.PlayerController:ServerUpdateCamera", tick)

function ops.ghost(a)
    queue[#queue + 1] = a
    return "queued ghost (runs when a player moves)"
end

function ops.unghost(a)
    queue[#queue + 1] = a
    return "queued unghost (runs when a player moves)"
end

-- wp.rev aggro threats|perception|tag <GameplayTag>|untag <GameplayTag>|hp <value>|clear
-- Ways to make mobs drop a ghost: unregister it from AI perception, give it a tag the AI treats
-- as dead, or clear every AI controller's focus. "threats" only logs what the mobs track.
function ops.aggro(a)
    queue[#queue + 1] = a
    return "queued aggro (runs when a player moves)"
end

local function threats_log()
    local n = 0
    for _, t in ipairs(FindAllOf("R5ThreatComponent") or {}) do
        local ok, list = pcall(function() return t:GetThreats() end)
        local names = {}
        if ok and list then
            pcall(function()
                list:ForEach(function(_, e)
                    local v = e:get()
                    local ok2, s = pcall(function() return v:GetFullName() end)
                    names[#names + 1] = ok2 and s or tostring(v)
                end)
            end)
        end
        if #names > 0 then
            log("threats of %s: %s", t:GetOwner():GetFullName(), table.concat(names, " | "))
            n = n + 1
        end
    end
    return n .. " mob(s) with threats"
end

function game.aggro(a)
    local name, mode = first_player(), a[2]
    local pawn = player_pawn(name or "")
    if mode == "threats" then return threats_log() end
    if not pawn then return "no pawn" end
    local lib = StaticFindObject("/Script/GameplayAbilities.Default__AbilitySystemBlueprintLibrary")
    if mode == "perception" then
        local out = {}
        for _, c in ipairs(FindAllOf("AIPerceptionStimuliSourceComponent") or {}) do
            if c:GetOwner():GetFullName() == pawn:GetFullName() then
                local ok, err = pcall(function() c:UnregisterFromPerceptionSystem() end)
                out[#out + 1] = tostring(ok) .. " " .. tostring(err or "")
            end
        end
        return "unregistered " .. #out .. " source(s): " .. table.concat(out, ", ")
    elseif mode == "tag" or mode == "untag" then
        -- A Lua table for FGameplayTagContainer crashed UE4SS (21.10.2026), so the container is
        -- built by the engine from a single tag.
        local tags = StaticFindObject("/Script/GameplayTags.Default__BlueprintGameplayTagLibrary")
        local container = tags:MakeGameplayTagContainerFromTag({ TagName = FName(a[3]) })
        local fn = mode == "tag" and "AddLooseGameplayTags" or "RemoveLooseGameplayTags"
        local ok, res = pcall(function() return lib[fn](lib, pawn, container, true) end)
        return fn .. " " .. tostring(a[3]) .. " -> " .. tostring(ok) .. " " .. tostring(res)
    elseif mode == "hp" then
        -- Write Health on the player's attribute set directly (like wp.bot hp), no effect runs.
        local ps = pawn.PlayerState
        local path = ps:GetFullName():match("^%S+ (.+)$")
        for _, set in ipairs(FindAllOf("R5AttributeSet") or {}) do
            if set:GetOuter():IsValid() and set:GetOuter():GetFullName():match("^%S+ (.+)$") == path then
                local v = tonumber(a[3]) or 0
                set.Health = { BaseValue = v, CurrentValue = v }
                return string.format("health now %.1f/%.1f", set.Health.CurrentValue, set.MaxHealth.CurrentValue)
            end
        end
        return "no attribute set"
    elseif mode == "clear" then
        local n = 0
        for _, c in ipairs(FindAllOf("AIController") or {}) do
            pcall(function()
                local f = c:GetFocusActor()
                if f and f:IsValid() and f:GetFullName() == pawn:GetFullName() then
                    c:K2_ClearFocus()
                    c:StopMovement()
                    n = n + 1
                end
            end)
        end
        return "cleared focus on " .. n .. " controller(s)"
    end
    return "usage: aggro threats|perception|tag <tag>|untag <tag>|clear"
end

function game.ghost(a)
    local name = a[2] or first_player()
    local pawn = player_pawn(name or "")
    if not pawn then return "no pawn for " .. tostring(name) end
    local death = deaths[name]
    if not death then return "no death location for " .. name end
    -- Mobs keep attacking a ghost on the ground (tags, zero health and focus do not help, see
    -- docs/plan.md), so the ghost hangs above the death spot where they cannot reach it.
    local to = { X = death.X, Y = death.Y, Z = death.Z + (tonumber(a[3]) or 1500) }
    local here = pawn:K2_GetActorLocation()
    ghosts[name] = { X = here.X, Y = here.Y, Z = here.Z }
    local ok, err = pcall(function() pawn:K2_TeleportTo(to, pawn:K2_GetActorRotation()) end)
    local res = set_ghost(pawn, true)
    log("ghost %s: teleport %s %s, %s", name, tostring(ok), tostring(err or ""), res)
    return "ghost " .. name .. ": teleport=" .. tostring(ok) .. " " .. res
end

function game.unghost(a)
    local name = a[2] or first_player()
    local pawn = player_pawn(name or "")
    if not pawn then return "no pawn for " .. tostring(name) end
    local res = set_ghost(pawn, false)
    if a[3] == "back" and ghosts[name] then
        pcall(function() pawn:K2_TeleportTo(ghosts[name], pawn:K2_GetActorRotation()) end)
    end
    ghosts[name] = nil
    log("unghost %s %s: %s", name, a[3] or "", res)
    return "unghost " .. name .. ": " .. res
end

RegisterHook("/Script/R5.R5ReviveComponent:OnPawnDead", function(self, actor)
    pcall(function()
        local a = actor:get()
        local name = self:get():GetOwner().PlayerNamePrivate:ToString()
        local l = a:K2_GetActorLocation()
        deaths[name] = { X = l.X, Y = l.Y, Z = l.Z }
        save_deaths()
        log("death %s at %.0f %.0f %.0f", name, l.X, l.Y, l.Z)
    end)
end)

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
    if not op then return "usage: wp.rev classes|info|set <prop> <number>|ghost [name]|unghost [name] [back]|aggro <mode>" end
    local ok, res = pcall(op, args)
    return ok and tostring(res) or ("failed: " .. tostring(res))
end, "Revive spike", "wp.rev classes|info|set")

log("partyrevive spike loaded")
