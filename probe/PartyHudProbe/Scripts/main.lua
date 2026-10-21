-- P0 probe: F7 logs health, distance and gameplay tags of every player in GameState.PlayerArray.
-- Output goes to UE4SS.log. The player attribute set lives on the PlayerState (first probe, 21.10.2026).

local function fstr(v)
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or tostring(v)
end

-- Reads an FGameplayAttributeData field, nil if the set has no such attribute.
local function attr(set, field)
    local ok, v = pcall(function() return set[field].CurrentValue end)
    if ok and type(v) == "number" then return v end
    return nil
end

local function attribute_set_of(ps)
    local prefix = ps:GetFullName():match("^%S+ (.+)$")
    for _, set in ipairs(FindAllOf("R5AttributeSet") or {}) do
        if set:GetOuter():IsValid() and set:GetOuter():GetFullName():match("^%S+ (.+)$") == prefix then
            return set
        end
    end
    return nil
end

local function asc_of(ps)
    local ok, asc = pcall(function() return ps.AbilitySystemComponent end)
    if ok and asc and asc:IsValid() then return asc, "property" end
    for _, c in ipairs(FindAllOf("AbilitySystemComponent") or {}) do
        local ok2, owner = pcall(function() return c:GetOwner() end)
        if ok2 and owner and owner:IsValid() and owner:GetFullName() == ps:GetFullName() then
            return c, "search"
        end
    end
    return nil, "none"
end

-- Combat tag candidates from the client binary strings.
local COMBAT_TAGS = { "GAS.CharacterFsm.State.Combat", "GAS.Animation.State.Combat", "GAS.Character.Movement.Combat" }

-- Counts per combat tag candidate through ASC:GetGameplayTagCount. Neither the ASC nor the pawn
-- exposes a tag listing function (BP_/K2_GetOwnedGameplayTags are nil in Lua, 21.10.2026).
local function combat_counts(asc)
    local out = {}
    for _, t in ipairs(COMBAT_TAGS) do
        local ok, n = pcall(function() return asc:GetGameplayTagCount({ TagName = FName(t) }) end)
        out[#out + 1] = t .. "=" .. (ok and tostring(n) or "err")
    end
    return table.concat(out, " ")
end

local function probe()
    local lines = { os.date("== %Y-%m-%d %H:%M:%S") }
    local pc = FindFirstOf("PlayerController")
    local here = pc and pc:IsValid() and pc.Pawn:IsValid() and pc.Pawn:K2_GetActorLocation() or nil
    local gs = FindFirstOf("GameStateBase")
    if not gs or not gs:IsValid() then return print("[PartyHudProbe] no GameState\n") end
    gs.PlayerArray:ForEach(function(_, ref)
        local ps = ref:get()
        local set = attribute_set_of(ps)
        local hp = set and attr(set, "Health")
        local max = set and attr(set, "MaxHealth")
        local dist = "-"
        local pawn = ps:GetPawn()
        if here and pawn:IsValid() then
            local p = pawn:K2_GetActorLocation()
            local dx, dy, dz = p.X - here.X, p.Y - here.Y, p.Z - here.Z
            dist = string.format("%.0fm", math.sqrt(dx * dx + dy * dy + dz * dz) / 100)
        end
        local asc, found = asc_of(ps)
        lines[#lines + 1] = string.format("%s hp=%s/%s dist=%s asc=%s(%s) combat[%s]",
            fstr(ps.PlayerNamePrivate), tostring(hp), tostring(max), dist,
            asc and asc:GetClass():GetFName():ToString() or "-", found, asc and combat_counts(asc) or "-")
    end)
    print("[PartyHudProbe]\n" .. table.concat(lines, "\n") .. "\n")
end

-- State tags of the character FSM and combat animation, counted per player by the watcher.
local WATCH_TAGS = {
    fsmCombat = "GAS.CharacterFsm.State.Combat", fsmBuild = "GAS.CharacterFsm.State.Building",
    fsmPreDeath = "GAS.CharacterFsm.State.PreDeath", fsmDeath = "GAS.CharacterFsm.State.Death",
    animCombat = "GAS.Animation.State.Combat", moveCombat = "GAS.Character.Movement.Combat",
}
local WATCH_ORDER = { "fsmCombat", "animCombat", "moveCombat", "fsmBuild", "fsmPreDeath", "fsmDeath" }

local watching, last = false, {}

local function snapshot(ps)
    local set = attribute_set_of(ps)
    local parts = { string.format("hp=%s/%s", tostring(set and attr(set, "Health")), tostring(set and attr(set, "MaxHealth"))) }
    local asc = asc_of(ps)
    for _, k in ipairs(WATCH_ORDER) do
        local ok, n = pcall(function() return asc:GetGameplayTagCount({ TagName = FName(WATCH_TAGS[k]) }) end)
        parts[#parts + 1] = k .. "=" .. (ok and tostring(n) or "err")
    end
    return table.concat(parts, " ")
end

-- Logs a line per player whenever health or one of the watched tags changes.
local function watch_tick()
    local gs = FindFirstOf("GameStateBase")
    if not gs or not gs:IsValid() then return end
    gs.PlayerArray:ForEach(function(_, ref)
        local ps = ref:get()
        local name = fstr(ps.PlayerNamePrivate)
        local s = snapshot(ps)
        if last[name] ~= s then
            print(string.format("[PartyHudProbe] %s %s %s\n", os.date("%H:%M:%S"), name, s))
            last[name] = s
        end
    end)
end

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(probe)
        if not ok then print("[PartyHudProbe] error: " .. tostring(err) .. "\n") end
    end)
end)

RegisterKeyBind(Key.F8, function()
    watching = not watching
    last = {}
    print("[PartyHudProbe] watch " .. (watching and "on" or "off") .. "\n")
    if not watching then return end
    LoopAsync(250, function()
        if not watching then return true end
        ExecuteInGameThread(function()
            local ok, err = pcall(watch_tick)
            if not ok then print("[PartyHudProbe] watch error: " .. tostring(err) .. "\n") end
        end)
        return false
    end)
end)

print("[PartyHudProbe] loaded, F7 to probe, F8 to toggle watch\n")
