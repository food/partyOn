-- PartyOn: a panel with name and health bar for every other player on the server.
-- Built from plain UMG classes at runtime, so no cooked widget blueprint is needed.
-- Health comes from the R5AttributeSet on each PlayerState, which every client receives.
-- Windrose has no "in combat" flag (see docs/plan.md), so a player counts as fighting for a
-- while after losing health or while the combat animation tag is set.
-- Settings live in config.lua; the toggle key hides and shows the panel.
--
-- Revive (needs the Party On server mod): after death the player picks respawn or waiting
-- as a ghost; a ghost can cancel; a living player near a ghost's death spot revives him. The
-- client only sends "partyon <cmd>" through ServerExecRPC and reads ghost state from the
-- pawn's replicated bHidden; the server decides everything else.

local CFG = {
    x = 40, y = 300, scale = 1.0, combat_seconds = 10, toggle_key = "F9",
    key_respawn = "F5", key_wait = "F6", key_cancel = "F5", key_help = "F7",
    marker = "fire", fire_scale = 1.0,
}
local ok_cfg, user_cfg = pcall(require, "config")
if ok_cfg and type(user_cfg) == "table" then
    for k, v in pairs(user_cfg) do CFG[k] = v end
end

local UPDATE_MS = 250
local WIDGET_NAME = "PartyOnWidget"
-- A hot reload (Ctrl+R) can leave the previous instance's loop running with its own widget and
-- state. Every instance tags its widget with a generation; an older one retires when it sees a
-- newer widget.
local GEN = os.time() * 1000 + math.random(0, 999)
local retired = false
local COMBAT_TAG = "GAS.Animation.State.Combat"
local COLOR = {
    normal = { R = 1, G = 1, B = 1, A = 1 },
    combat = { R = 1, G = 0.6, B = 0.1, A = 1 },
    dead = { R = 0.55, G = 0.55, B = 0.55, A = 1 },
    ghost = { R = 0.55, G = 0.8, B = 1, A = 1 },
    bar = { R = 0.75, G = 0.12, B = 0.12, A = 1 },
}
-- Must match server/partyon/revive.lua.
local HOVER = 1500       -- cm a ghost hangs above its death spot
local HELP_RADIUS = 500  -- cm, horizontal
local HELP_RADIUS_Z = 400
local DECIDE_SECONDS = 18  -- server accepts "wait" up to 20 s after death
local BEAM_HEIGHT = 20000  -- cm, red pillar from a ghost's death spot up into the sky
local BEAM_WIDTH = 0.4     -- scale of the 1 m engine cylinder

local hud = nil       -- { widget, tree, box, prompt, rows = { [name] = row }, order = "a\nb" }
local lookup = {}     -- [name] = { ps, set, asc } cached per PlayerState
local fight = {}      -- [name] = { hp = last seen health, at = os.time() of last hit }
local visible = true
local me = {}         -- own revive state: died_at, choice ("wait"|"respawn"), was_ghost
local help_target = nil
local beams = {}      -- [name] = local StaticMeshActor marking a ghost's death spot

local function valid(o)
    return o ~= nil and o:IsValid()
end

local function fstr(v)
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or "?"
end

local function new(class, outer, name)
    return StaticConstructObject(StaticFindObject(class), outer, FName(name))
end

local function path_of(o)
    return o:GetFullName():match("^%S+ (.+)$")
end

local function find_parts(ps)
    local path, set, asc = path_of(ps), nil, nil
    for _, s in ipairs(FindAllOf("R5AttributeSet") or {}) do
        if s:GetOuter():IsValid() and path_of(s:GetOuter()) == path then set = s; break end
    end
    for _, c in ipairs(FindAllOf("AbilitySystemComponent") or {}) do
        local ok, owner = pcall(function() return c:GetOwner() end)
        if ok and valid(owner) and path_of(owner) == path then asc = c; break end
    end
    return { ps = ps, set = set, asc = asc }
end

-- Attribute set and ASC per player, looked up again when the PlayerState changes.
local function parts_of(name, ps)
    local p = lookup[name]
    if not p or not valid(p.ps) or path_of(p.ps) ~= path_of(ps) or not valid(p.set) then
        p = find_parts(ps)
        lookup[name] = p
    end
    return p
end

local function in_combat(name, hp, asc)
    local f = fight[name]
    if not f then
        f = { hp = hp, at = 0 }
        fight[name] = f
    end
    local now = os.time()
    if hp < f.hp then f.at = now end
    f.hp = hp
    if valid(asc) then
        local ok, n = pcall(function() return asc:GetGameplayTagCount({ TagName = FName(COMBAT_TAG) }) end)
        if ok and n and n > 0 then f.at = now end
    end
    return now - f.at < CFG.combat_seconds
end

-- Generations of all PartyOn widgets in the viewport. Names are unique per generation: with a
-- shared name a reloaded instance got the old widget object back and both wrote into it.
local function widget_gens()
    local out = {}
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        local gen = tonumber(w:GetFName():ToString():match("^" .. WIDGET_NAME .. "_(%d+)"))
        if gen then out[#out + 1] = { gen = gen, widget = w } end
    end
    return out
end

local function newer_instance_running()
    for _, e in ipairs(widget_gens()) do
        if e.gen > GEN then return true end
    end
    return false
end

local function build()
    for _, e in ipairs(widget_gens()) do
        if e.gen <= GEN then pcall(function() e.widget:RemoveFromParent() end) end
    end
    local gi = FindFirstOf("GameInstance")
    if not valid(gi) then return nil end
    local widget = new("/Script/UMG.UserWidget", gi, WIDGET_NAME .. "_" .. GEN .. "_" .. math.random(0, 1e6))
    local tree = new("/Script/UMG.WidgetTree", widget, "PartyOnTree")
    widget.WidgetTree = tree
    local canvas = new("/Script/UMG.CanvasPanel", tree, "PartyOnCanvas")
    tree.RootWidget = canvas
    local box = new("/Script/UMG.VerticalBox", tree, "PartyOnBox")
    local slot = canvas:AddChildToCanvas(box)
    slot:SetPosition({ X = CFG.x, Y = CFG.y })
    slot:SetAutoSize(true)
    -- Revive prompt, centred a bit below the middle of the screen.
    local prompt = new("/Script/UMG.TextBlock", tree, "PartyOnPrompt")
    pcall(function()
        local font = prompt.Font
        font.Size = math.floor(20 * CFG.scale + 0.5)
        prompt:SetFont(font)
    end)
    prompt:SetShadowOffset({ X = 1, Y = 1 })
    prompt:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.9 })
    local ps = canvas:AddChildToCanvas(prompt)
    ps:SetAnchors({ Minimum = { X = 0.5, Y = 0.65 }, Maximum = { X = 0.5, Y = 0.65 } })
    ps:SetAlignment({ X = 0.5, Y = 0.5 })
    ps:SetAutoSize(true)
    widget:AddToViewport(50)
    if not visible then widget:SetVisibility(1) end
    return { widget = widget, tree = tree, box = box, prompt = prompt, prompt_text = "", rows = {}, order = "" }
end

local function new_row(name)
    local id = string.format("PartyOnRow_%d", math.random(0, 1e9))
    local label = new("/Script/UMG.TextBlock", hud.tree, id .. "Label")
    pcall(function()
        local font = label.Font
        font.Size = math.floor(14 * CFG.scale + 0.5)
        label:SetFont(font)
    end)
    label:SetShadowOffset({ X = 1, Y = 1 })
    label:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.8 })
    local size = new("/Script/UMG.SizeBox", hud.tree, id .. "Size")
    size:SetWidthOverride(220 * CFG.scale)
    size:SetHeightOverride(10 * CFG.scale)
    local bar = new("/Script/UMG.ProgressBar", hud.tree, id .. "Bar")
    bar:SetFillColorAndOpacity(COLOR.bar)
    size:AddChild(bar)
    hud.rows[name] = { label = label, size = size, bar = bar, state = nil }
end

-- Rows are kept sorted by name; the box is refilled only when players join or leave.
local function arrange(names)
    table.sort(names)
    local order = table.concat(names, "\n")
    if order == hud.order then return end
    hud.order = order
    hud.box:ClearChildren()
    for _, name in ipairs(names) do
        local row = hud.rows[name]
        hud.box:AddChildToVerticalBox(row.label)
        local s = hud.box:AddChildToVerticalBox(row.size)
        s:SetPadding({ Left = 0, Top = 2 * CFG.scale, Right = 0, Bottom = 8 * CFG.scale })
    end
end

local function show(row, name, hp, max, fighting, ghost)
    local state = ghost and "ghost" or hp <= 0 and "dead" or (fighting and "combat" or "normal")
    local text
    if state == "ghost" then
        text = name .. "  wartet auf Hilfe"
    elseif state == "dead" then
        text = name .. "  tot"
    else
        text = string.format("%s  %.0f / %.0f%s", name, hp, max, fighting and "  Kampf" or "")
    end
    if row.text ~= text then
        row.label:SetText(FText(text))
        row.text = text
    end
    if row.state ~= state then
        row.label:SetColorAndOpacity({ SpecifiedColor = COLOR[state], ColorUseRule = 0 })
        row.state = state
    end
    row.bar:SetPercent((max > 0 and not ghost) and math.max(hp, 0) / max or 0)
end

local function own_controller()
    local pc = FindFirstOf("PlayerController")
    if valid(pc) and valid(pc.PlayerState) then return pc end
end

local function pawn_of(ps)
    local ok, p = pcall(function() return ps:GetPawn() end)
    if ok and valid(p) then return p end
end

local function is_ghost(pawn)
    local ok, hidden = pcall(function() return pawn.bHidden end)
    return ok and hidden == true
end

local function send(cmd)
    local pc = own_controller()
    if pc then pcall(function() pc:ServerExecRPC("partyon " .. cmd) end) end
end

-- Own revive state from own health and ghost flag; returns the prompt line for it.
local function own_prompt(hp, max, ghost)
    local now = os.time()
    -- Right after login the attribute set reads 0/0 until the game fills it; that is no death.
    if hp and max and max > 0 and hp <= 0 and not me.died_at then me.died_at, me.choice = now, nil end
    if ghost then
        me.was_ghost = true
        return string.format("Geist: du wartest auf Hilfe.   [%s] Abbruch", CFG.key_cancel)
    end
    if me.was_ghost or (me.died_at and now - me.died_at > DECIDE_SECONDS + 2) then me = {} end
    if not me.died_at then return nil end
    if me.choice == "wait" then return "Warte auf Hilfe ..." end
    if not me.choice and now - me.died_at <= DECIDE_SECONDS then
        return string.format("[%s] Wiederbeleben     [%s] Auf Hilfe warten     (%d s)",
            CFG.key_respawn, CFG.key_wait, DECIDE_SECONDS - (now - me.died_at))
    end
end

local function set_prompt(text)
    text = text or ""
    if hud.prompt_text == text then return end
    hud.prompt:SetText(FText(text))
    hud.prompt_text = text
end

-- Red pillars over ghosts' death spots, spawned only on this client (not replicated) from the
-- engine's basic cylinder and material, which the game ships.
local beam_assets = nil

local function load_beam_assets()
    if beam_assets ~= nil then return beam_assets or nil end
    local mesh_path = "/Engine/BasicShapes/Cylinder.Cylinder"
    local mat_path = "/Engine/BasicShapes/BasicShapeMaterial.BasicShapeMaterial"
    -- LoadAsset needs the full object path; the package path alone loaded nothing.
    pcall(function() LoadAsset(mesh_path) end)
    pcall(function() LoadAsset(mat_path) end)
    local mesh, mat = StaticFindObject(mesh_path), StaticFindObject(mat_path)
    if not valid(mesh) then
        beam_assets = false
        print("[PartyOn] cylinder mesh not found, no pillars\n")
        return nil
    end
    beam_assets = { mesh = mesh, mat = valid(mat) and mat or nil }
    return beam_assets
end

local function spawn_beam(spot)
    local assets = load_beam_assets()
    local pc = own_controller()
    if not assets or not pc then return nil end
    local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local t = {
        Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
        Translation = { X = spot.X, Y = spot.Y, Z = spot.Z + BEAM_HEIGHT / 2 },
        Scale3D = { X = BEAM_WIDTH, Y = BEAM_WIDTH, Z = BEAM_HEIGHT / 100 },
    }
    local a = statics:BeginDeferredActorSpawnFromClass(pc, StaticFindObject("/Script/Engine.StaticMeshActor"), t, 1, nil, 0)
    if not valid(a) then return nil end
    statics:FinishSpawningActor(a, t, 0)
    local c = a.StaticMeshComponent
    pcall(function() c:SetMobility(2) end)
    c:SetStaticMesh(assets.mesh)
    pcall(function() c:SetCollisionEnabled(0) end)
    pcall(function() c:SetCastShadow(false) end)
    pcall(function() a:SetActorEnableCollision(false) end)
    if assets.mat then
        pcall(function()
            local mid = c:CreateDynamicMaterialInstance(0, assets.mat, FName("PartyOnBeamMat"))
            mid:SetVectorParameterValue(FName("Color"), { R = 1, G = 0, B = 0, A = 1 })
        end)
    end
    return a
end

-- The game's signal fire effect. It exposes no user parameters, so its color cannot be changed
-- (FireTint is internal; checked 21.10.2026).
local FIRE_PATH = "/Game/FX/Particles/Environment/Fire/FX_SignalFire.FX_SignalFire"

local function spawn_fire(spot)
    local pc = own_controller()
    if not pc then return nil end
    pcall(function() LoadAsset(FIRE_PATH) end)
    local system = StaticFindObject(FIRE_PATH)
    if not valid(system) then return nil end
    local lib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
    local c = lib:SpawnSystemAtLocation(pc, system, spot, { Pitch = 0, Yaw = 0, Roll = 0 },
        { X = CFG.fire_scale, Y = CFG.fire_scale, Z = CFG.fire_scale }, false, true, 0, false)
    if not valid(c) then return nil end
    return c
end

local function destroy_marker(m)
    pcall(function()
        if m:IsA("/Script/Engine.Actor") then
            m:K2_DestroyActor()
        else
            pcall(function() m:DeactivateImmediate() end)
            m:K2_DestroyComponent(m)
        end
    end)
end

-- Keeps one marker (signal fire or pillar, see config.lua) per ghost at its death spot and
-- removes the rest.
local function sync_beams(spots)
    for name, a in pairs(beams) do
        if not spots[name] then
            destroy_marker(a)
            beams[name] = nil
        end
    end
    for name, spot in pairs(spots) do
        if not valid(beams[name]) then
            local ok, a = pcall(CFG.marker == "pillar" and spawn_beam or spawn_fire, spot)
            if ok and a then
                beams[name] = a
                print(string.format("[PartyOn] %d beam for %s\n", GEN, name))
            elseif not ok then
                print(string.format("[PartyOn] beam for %s failed: %s\n", name, tostring(a)))
            end
        end
    end
end

local ticks = 0

local function update()
    ticks = ticks + 1
    if ticks % 8 == 0 and newer_instance_running() then
        retired = true
        if hud and valid(hud.widget) then pcall(function() hud.widget:RemoveFromParent() end) end
        sync_beams({})
        print(string.format("[PartyOn] %d retired, a newer instance runs\n", GEN))
        return
    end
    if not hud or not valid(hud.widget) then hud = build() end
    if not hud then return end
    local gs = FindFirstOf("GameStateBase")
    local pc = own_controller()
    if not valid(gs) or not pc then return end
    local my_name, names = fstr(pc.PlayerState.PlayerNamePrivate), {}
    local my_pawn = pawn_of(pc.PlayerState)
    local here = my_pawn and my_pawn:K2_GetActorLocation()
    local my_ghost = my_pawn ~= nil and is_ghost(my_pawn)
    local best, best_d = nil, nil
    local my_hp, my_max
    local ghost_spots = {}
    gs.PlayerArray:ForEach(function(_, ref)
        local ps = ref:get()
        local name = fstr(ps.PlayerNamePrivate)
        local p = parts_of(name, ps)
        if not valid(p.set) then return end
        local hp, max = p.set.Health.CurrentValue, p.set.MaxHealth.CurrentValue
        if name == my_name then my_hp, my_max = hp, max; return end
        local pawn = pawn_of(ps)
        local ghost = pawn ~= nil and is_ghost(pawn)
        if ghost then
            local g = pawn:K2_GetActorLocation()
            ghost_spots[name] = { X = g.X, Y = g.Y, Z = g.Z - HOVER }
        end
        if ghost and here and not my_ghost then
            local g = pawn:K2_GetActorLocation()
            local dx, dy, dz = g.X - here.X, g.Y - here.Y, g.Z - HOVER - here.Z
            local d = math.sqrt(dx * dx + dy * dy)
            if d <= HELP_RADIUS and math.abs(dz) <= HELP_RADIUS_Z and (not best_d or d < best_d) then
                best, best_d = name, d
            end
        end
        names[#names + 1] = name
        if not hud.rows[name] then new_row(name) end
        show(hud.rows[name], name, hp, max, not ghost and in_combat(name, hp, p.asc), ghost)
    end)
    local present = {}
    for _, n in ipairs(names) do present[n] = true end
    for name in pairs(hud.rows) do
        if not present[name] then hud.rows[name], fight[name], lookup[name] = nil, nil, nil end
    end
    arrange(names)
    sync_beams(ghost_spots)
    help_target = best
    local text = own_prompt(my_hp, my_max, my_ghost)
    if not text and best then text = string.format("[%s] Wiederbeleben: %s", CFG.key_help, best) end
    set_prompt(text)
end

-- Revive keys: one handler per key, the first action that applies to the current state wins.
local function deciding()
    return me.died_at and not me.choice and not me.was_ghost and os.time() - me.died_at <= DECIDE_SECONDS
end

local ACTIONS = {
    { key = CFG.key_cancel, when = function() return me.was_ghost end, run = function() send("cancel") end },
    { key = CFG.key_respawn, when = deciding, run = function() me.choice = "respawn"; send("respawn") end },
    { key = CFG.key_wait, when = deciding, run = function() me.choice = "wait"; send("wait") end },
    { key = CFG.key_help, when = function() return help_target ~= nil end, run = function() send("help") end },
}

local bound = {}
for _, a in ipairs(ACTIONS) do
    if Key[a.key] and not bound[a.key] then
        bound[a.key] = true
        RegisterKeyBind(Key[a.key], function()
            if retired then return end
            ExecuteInGameThread(function()
                for _, b in ipairs(ACTIONS) do
                    if b.key == a.key and b.when() then
                        pcall(b.run)
                        return
                    end
                end
            end)
        end)
    end
end

RegisterKeyBind(Key[CFG.toggle_key] or Key.F9, function()
    if retired then return end
    visible = not visible
    ExecuteInGameThread(function()
        if hud and valid(hud.widget) then
            -- ESlateVisibility: 1 = Collapsed, 3 = HitTestInvisible
            hud.widget:SetVisibility(visible and 3 or 1)
        end
    end)
end)

LoopAsync(UPDATE_MS, function()
    if retired then return true end
    ExecuteInGameThread(function()
        local ok, err = pcall(update)
        if not ok then print("[PartyOn] " .. tostring(err) .. "\n") end
    end)
    return false
end)

print(string.format("[PartyOn] %d loaded (%s), %s toggles the panel\n", GEN,
    ok_cfg and "config.lua" or "defaults: " .. tostring(user_cfg), CFG.toggle_key))
