-- P0 probe: Ctrl+F7 logs health, owner and combat tags of every attribute set the client knows.
-- Output goes to UE4SS.log and Mods/PartyHudProbe/probe.txt.

local OUT = "Mods/PartyHudProbe/probe.txt"

local function name_of(obj)
    local ok, s = pcall(function() return obj:GetFullName() end)
    return ok and s or tostring(obj)
end

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

local function local_pawn_location()
    local pc = FindFirstOf("PlayerController")
    if not pc or not pc:IsValid() or not pc.Pawn:IsValid() then return nil end
    return pc.Pawn:K2_GetActorLocation()
end

-- Player name and distance in metres for the actor that owns an ability system component.
local function describe_owner(asc, here)
    local ok, owner = pcall(function() return asc:GetOwner() end)
    if not ok or not owner or not owner:IsValid() then return "owner ?" end
    local ps, pawn = nil, nil
    if owner:IsA("/Script/Engine.PlayerState") then
        ps = owner
        pcall(function() pawn = owner:GetPawn() end)
    elseif owner:IsA("/Script/Engine.Pawn") then
        pawn = owner
        pcall(function() ps = owner.PlayerState end)
    end
    local who = "npc"
    if ps and ps:IsValid() then who = fstr(ps.PlayerNamePrivate) end
    local dist = "-"
    if here and pawn and pawn:IsValid() then
        local p = pawn:K2_GetActorLocation()
        local dx, dy, dz = p.X - here.X, p.Y - here.Y, p.Z - here.Z
        dist = string.format("%.0fm", math.sqrt(dx * dx + dy * dy + dz * dz) / 100)
    end
    return string.format("%s owner=%s dist=%s", who, owner:GetClass():GetFName():ToString(), dist)
end

local function combat_tags(asc)
    local tags = {}
    for _, fn in ipairs({ "GetOwnedGameplayTags", "K2_GetOwnedGameplayTags" }) do
        local ok, container = pcall(function() return asc[fn](asc) end)
        if ok and container then
            pcall(function()
                container.GameplayTags:ForEach(function(_, tag)
                    local t = tag:get().TagName:ToString()
                    if t:lower():find("combat", 1, true) then tags[#tags + 1] = t end
                end)
            end)
            return #tags > 0 and table.concat(tags, ",") or "none", fn
        end
    end
    return "n/a", "-"
end

local function probe()
    local lines = { os.date("== %Y-%m-%d %H:%M:%S") }
    local here = local_pawn_location()
    local sets = FindAllOf("AttributeSet") or {}
    for _, set in ipairs(sets) do
        local hp, max = attr(set, "Health"), attr(set, "MaxHealth")
        if hp then
            local asc = set:GetOuter()
            local tags, via = combat_tags(asc)
            lines[#lines + 1] = string.format("%s hp=%.1f/%s temp=%s | %s | combat=%s (%s) | %s",
                set:GetClass():GetFName():ToString(), hp, max and string.format("%.1f", max) or "?",
                tostring(attr(set, "TemporalHealth")), describe_owner(asc, here), tags, via, name_of(set))
        end
    end
    local gs = FindFirstOf("GameStateBase")
    if gs and gs:IsValid() then
        gs.PlayerArray:ForEach(function(_, ps)
            ps = ps:get()
            lines[#lines + 1] = "player " .. fstr(ps.PlayerNamePrivate) .. " pawn=" .. tostring(ps:GetPawn():IsValid())
        end)
    end
    lines[#lines + 1] = string.format("%d attribute sets scanned", #sets)
    local text = table.concat(lines, "\n")
    print("[PartyHudProbe]\n" .. text .. "\n")
    local f = io.open(OUT, "a")
    if f then f:write(text, "\n"); f:close() end
end

RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(probe)
        if not ok then print("[PartyHudProbe] error: " .. tostring(err) .. "\n") end
    end)
end)

print("[PartyHudProbe] loaded, Ctrl+F7 to probe\n")
