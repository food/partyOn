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

local function owned_tags(asc, pawn)
    local errs = {}
    for _, target in ipairs({ asc, pawn }) do
        for _, fn in ipairs({ "BP_GetOwnedGameplayTags", "K2_GetOwnedGameplayTags", "GetOwnedGameplayTags" }) do
            local tags = {}
            local ok, err = pcall(function()
                target[fn](target).GameplayTags:ForEach(function(_, tag)
                    tags[#tags + 1] = tag:get().TagName:ToString()
                end)
            end)
            if ok then return table.concat(tags, ","), target:GetClass():GetFName():ToString() .. ":" .. fn end
            errs[#errs + 1] = fn .. ": " .. tostring(err):sub(1, 80)
        end
    end
    return "n/a", table.concat(errs, " / ")
end

-- Counts per combat tag candidate through ASC:GetGameplayTagCount, works without tag listing.
local function combat_counts(asc)
    local out = {}
    for _, t in ipairs(COMBAT_TAGS) do
        local ok, n = pcall(function() return asc:GetGameplayTagCount({ TagName = FName(t) }) end)
        out[#out + 1] = t:match("[^.]+%.[^.]+$") .. "=" .. (ok and tostring(n) or "err")
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
        local tags, via, counts = "n/a", "-", "-"
        if asc then
            tags, via = owned_tags(asc, pawn)
            counts = combat_counts(asc)
        end
        lines[#lines + 1] = string.format("%s hp=%s/%s dist=%s asc=%s(%s) combat[%s] tags[%s]=%s",
            fstr(ps.PlayerNamePrivate), tostring(hp), tostring(max), dist,
            asc and asc:GetClass():GetFName():ToString() or "-", found, counts, via, tags)
    end)
    print("[PartyHudProbe]\n" .. table.concat(lines, "\n") .. "\n")
end

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(probe)
        if not ok then print("[PartyHudProbe] error: " .. tostring(err) .. "\n") end
    end)
end)

print("[PartyHudProbe] loaded, F7 to probe\n")
