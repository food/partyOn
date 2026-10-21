-- Gallery of visual candidates for marking a ghost's death spot (see docs/visual-candidates.md).
-- F10 shows the next page in front of the player, F11 the same page again, F12 clears.
-- Effects and meshes are spawned locally in a row with a yellow name label; icons are shown
-- on screen.

local WORLD = {
    "/Game/FX/Particles/Environment/InteractiveObjects/PosthumousContainer/FX_PosthumousContainerLight",
    "/Game/FX/Particles/Environment/InteractiveObjects/PosthumousContainer/FX_PosthumousContainer",
    "/Game/FX/Particles/Environment/InteractiveObjects/PosthumousContainer/FX_PosthumousContainer_end_01",
    "/Game/FX/Particles/Environment/Fire/FX_SignalFire",
    "/Game/FX/Particles/Environment/InteractiveObjects/BossReset/FX_Wisp_Light_Altars",
    "/Game/FX/Particles/Mobs/Quest/Ghost/FX_QuestGhost_Spawn",
    "/Game/FX/Particles/Mobs/Quest/Ghost/FX_QuestGhost_Despawn",
    "/Game/FX/Particles/Bosses/HighLands/Israel/FX_Ghost_Chest_01",
    "/Game/FX/Particles/Bosses/HighLands/Israel/Trails/FX_GhostWeapon_Spawn",
    "/Game/FX/Particles/Consumables/CheatDeath/FX_CheatDeath_Use",
    "/Game/FX/Particles/Consumables/CheatDeath/FX_CheatDeath_TimeOut",
    "/Game/FX/Particles/Environment/Smoke/FX_SmokePoi",
    "/Game/FX/Particles/Environment/Smoke/FX_FireSmoke_Trail_01",
    "/Game/FX/Particles/Environment/InteractiveObjects/Pickup/FX_LootBox_Medium",
    "/Game/FX/Particles/Environment/Weather/Lightning/FX_Lightning_Strikes",
    "/Game/FX/Particles/Mobs/Shaman/FX_Witch_Totem_Death",
    "/Game/FX/Particles/Environment/Fire/FX_CandleSmoke_Altars",
    "/Game/FX/Meshes/Bosses/HighLands/Israel/SM_Beam_02",
    "/Game/Environment/Gameplay/Building/BuildingDecoration/SM_SignalFireT01",
    "/Game/Environment/Gameplay/Building/BuildingDecoration/SM_FloorTorch",
    "/Game/Environment/Props/FillingProps/SM_CultistTorch_01",
    "/Game/Environment/Gameplay/Building/Primitives/Decoration/SM_Flagpole_PR",
    "/Game/Environment/Gameplay/Building/BuildingDecoration/SM_FlagpoleT04",
    "/Game/FX/Meshes/Mobs/Witch/SM_Totem",
    "/Game/Environment/Props/NecroTotem/SM_Necrototem_02",
    "/Game/Environment/Props/StoneTotem/SM_StoneTotem_p10",
    "/Game/Environment/Props/DeadTree/Meshes/SM_MachtCross_Cloth01",
    "/Game/Character/Common/Artifact/SM_Artifact_Skull_01",
    "/Game/Character/Common/Accessoires/SM_Accessories_Lantern_01",
    "/Game/FX/Meshes/Environment/InteractiveObjects/PosthumousContainer/SM_Posthumous_03",
    "/Engine/BasicShapes/Cone",
}

local ICONS = {
    "/Game/UI/HUD/Navigation/UserCreatedMarkers/T_IconPOI_DeathPoint",
    "/Game/UI/HUD/Navigation/UserCreatedMarkers/T_IconPOI_Skull",
    "/Game/UI/HUD/Navigation/UserCreatedMarkers/T_IconPOI_Warning",
    "/Game/UI/HUD/Navigation/UserCreatedMarkers/T_IconPOI_Star",
    "/Game/UI/HUD/Navigation/PointsOfInterest/Icons/T_IconPOI_Marker_Check2",
    "/Game/UI/HUD/Navigation/UserCreatedMarkers/T_IconPOI_UserCreated",
    "/Game/UI/HUD/Navigation/PointsOfInterest/Icons/T_IconPOI_Quest",
    "/Game/UI/HUD/Navigation/PointsOfInterest/Icons/T_IconPOI_Treasure",
    "/Game/UI/HUD/Navigation/PointsOfInterest/Icons/T_IconPOI_Mystery",
    "/Game/UI/HUD/Navigation/PointsOfInterest/Icons/T_MapIcon_Undeads",
    "/Game/UI/HUD/Navigation/PointsOfInterest/Icons/T_MapIcon_Firebowl",
    "/Game/UI/Icons/Items/Jewelry/T_ItemIcon_Ring_SilverSkull_01",
    "/Game/UI/Icons/Items/Jewelry/T_ItemIcon_Ring_RubyHeart_01",
}

local WORLD_PAGE, SPACING, AHEAD = 4, 500, 700   -- per page, cm between, cm in front
local pages = {}
for i = 1, #WORLD, WORLD_PAGE do
    local p = {}
    for j = i, math.min(i + WORLD_PAGE - 1, #WORLD) do p[#p + 1] = WORLD[j] end
    pages[#pages + 1] = { kind = "world", items = p }
end
pages[#pages + 1] = { kind = "icons", items = ICONS }

local page = 0
local spawned = {}   -- actors and components to clean up
local overlay = nil  -- icon widget

local function valid(o)
    return o ~= nil and o:IsValid()
end

local function short(path)
    return path:match("[^/]+$")
end

local function load(path)
    local full = path .. "." .. short(path)
    pcall(function() LoadAsset(full) end)
    local o = StaticFindObject(full)
    return valid(o) and o or nil
end

local function clear()
    for _, o in ipairs(spawned) do
        pcall(function()
            if o:IsA("/Script/Engine.Actor") then
                o:K2_DestroyActor()
            else
                pcall(function() o:DeactivateImmediate() end)
                o:K2_DestroyComponent(o)
            end
        end)
    end
    spawned = {}
    if valid(overlay) then pcall(function() overlay:RemoveFromParent() end) end
    overlay = nil
end

local function spawn_actor(pc, class, loc, rot, scale)
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local q = { X = 0, Y = 0, Z = math.sin(math.rad(rot) / 2), W = math.cos(math.rad(rot) / 2) }
    local t = { Rotation = q, Translation = loc, Scale3D = scale or { X = 1, Y = 1, Z = 1 } }
    local a = statics:BeginDeferredActorSpawnFromClass(pc, StaticFindObject(class), t, 1, nil, 0)
    if not valid(a) then return nil end
    statics:FinishSpawningActor(a, t, 0)
    spawned[#spawned + 1] = a
    return a
end

local function label(pc, text, loc, yaw)
    local a = spawn_actor(pc, "/Script/Engine.TextRenderActor", loc, yaw)
    if not a then return end
    local c = a.TextRender
    c:SetText(FText(text))
    pcall(function() c:SetTextRenderColor({ R = 255, G = 220, B = 0, A = 255 }) end)
    pcall(function() c:SetWorldSize(26) end)
    pcall(function() c:SetHorizontalAlignment(1) end)
end

-- Effect (Niagara or Cascade) or mesh at loc; returns a short status for the label.
local function show_world(pc, path, loc)
    local obj = load(path)
    if not obj then return "not found" end
    local cls = obj:GetClass():GetFName():ToString()
    if cls == "NiagaraSystem" then
        local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        local c = lib:SpawnSystemAtLocation(pc, obj, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, false, true, 0, false)
        if valid(c) then spawned[#spawned + 1] = c end
    elseif cls == "ParticleSystem" then
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local c = statics:SpawnEmitterAtLocation(pc, obj, loc, { Pitch = 0, Yaw = 0, Roll = 0 }, { X = 1, Y = 1, Z = 1 }, false, 0, false)
        if valid(c) then spawned[#spawned + 1] = c end
    elseif cls == "StaticMesh" then
        local a = spawn_actor(pc, "/Script/Engine.StaticMeshActor", loc, 0)
        if a then
            pcall(function() a.StaticMeshComponent:SetMobility(2) end)
            a.StaticMeshComponent:SetStaticMesh(obj)
            pcall(function() a:SetActorEnableCollision(false) end)
        end
    end
    return cls
end

local function show_icons(items)
    local gi = FindFirstOf("GameInstance")
    local function new(class, outer, name)
        return StaticConstructObject(StaticFindObject(class), outer, FName(name .. "_" .. math.random(0, 1e9)))
    end
    overlay = new("/Script/UMG.UserWidget", gi, "PartyHudGallery")
    local tree = new("/Script/UMG.WidgetTree", overlay, "GalleryTree")
    overlay.WidgetTree = tree
    local canvas = new("/Script/UMG.CanvasPanel", tree, "GalleryCanvas")
    tree.RootWidget = canvas
    for i, path in ipairs(items) do
        local col, row = (i - 1) % 5, math.floor((i - 1) / 5)
        local x, y = 300 + col * 260, 150 + row * 230
        local tex = load(path)
        if tex then
            local img = new("/Script/UMG.Image", tree, "GalleryImg")
            img:SetBrushFromTexture(tex, false)
            local s = canvas:AddChildToCanvas(img)
            s:SetPosition({ X = x, Y = y })
            s:SetSize({ X = 128, Y = 128 })
        end
        local t = new("/Script/UMG.TextBlock", tree, "GalleryText")
        t:SetText(FText(short(path) .. (tex and "" or " (not found)")))
        t:SetShadowOffset({ X = 1, Y = 1 })
        local s = canvas:AddChildToCanvas(t)
        s:SetPosition({ X = x, Y = y + 135 })
        s:SetAutoSize(true)
    end
    overlay:AddToViewport(60)
end

local function show(n)
    clear()
    local pc = FindFirstOf("PlayerController")
    if not valid(pc) or not valid(pc.Pawn) then return end
    page = ((n - 1) % #pages) + 1
    local p = pages[page]
    print(string.format("[PartyHudGallery] page %d/%d (%s)\n", page, #pages, p.kind))
    if p.kind == "icons" then return show_icons(p.items) end
    local pawn = pc.Pawn
    local here, fwd, right = pawn:K2_GetActorLocation(), pawn:GetActorForwardVector(), pawn:GetActorRightVector()
    local yaw = pawn:K2_GetActorRotation().Yaw + 180
    for i, path in ipairs(p.items) do
        local side = (i - (#p.items + 1) / 2) * SPACING
        local loc = {
            X = here.X + fwd.X * AHEAD + right.X * side,
            Y = here.Y + fwd.Y * AHEAD + right.Y * side,
            Z = here.Z - 80,
        }
        local ok, status = pcall(show_world, pc, path, loc)
        label(pc, short(path) .. (ok and "" or " (error)"), { X = loc.X, Y = loc.Y, Z = loc.Z + 260 }, yaw)
        print(string.format("[PartyHudGallery]   %s -> %s\n", short(path), ok and tostring(status) or tostring(status)))
    end
end

local function on_key(n)
    ExecuteInGameThread(function()
        local ok, err = pcall(show, n)
        if not ok then print("[PartyHudGallery] " .. tostring(err) .. "\n") end
    end)
end

RegisterKeyBind(Key.F10, function() on_key(page + 1) end)
RegisterKeyBind(Key.F11, function() on_key(math.max(page, 1)) end)
RegisterKeyBind(Key.F12, function() ExecuteInGameThread(clear) end)

print(string.format("[PartyHudGallery] loaded, %d pages: F10 next, F11 again, F12 clear\n", #pages))
