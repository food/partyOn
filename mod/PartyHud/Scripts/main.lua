-- PartyHud: a panel with name and health bar for every other player on the server.
-- Built from plain UMG classes at runtime, so no cooked widget blueprint is needed.
-- Health comes from the R5AttributeSet on each PlayerState, which every client receives.
-- Windrose has no "in combat" flag (see docs/plan.md), so a player counts as fighting for a
-- while after losing health or while the combat animation tag is set.
-- Settings live in config.lua; the toggle key hides and shows the panel.

local CFG = { x = 40, y = 300, scale = 1.0, combat_seconds = 10, toggle_key = "F9" }
local ok_cfg, user_cfg = pcall(require, "config")
if ok_cfg and type(user_cfg) == "table" then
    for k, v in pairs(user_cfg) do CFG[k] = v end
end

local UPDATE_MS = 250
local WIDGET_NAME = "PartyHudWidget"
local COMBAT_TAG = "GAS.Animation.State.Combat"
local COLOR = {
    normal = { R = 1, G = 1, B = 1, A = 1 },
    combat = { R = 1, G = 0.6, B = 0.1, A = 1 },
    dead = { R = 0.55, G = 0.55, B = 0.55, A = 1 },
    bar = { R = 0.75, G = 0.12, B = 0.12, A = 1 },
}

local hud = nil       -- { widget, tree, box, rows = { [name] = row }, order = "a\nb" }
local lookup = {}     -- [name] = { ps, set, asc } cached per PlayerState
local fight = {}      -- [name] = { hp = last seen health, at = os.time() of last hit }
local visible = true

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

-- A hot reload leaves the old widget in the viewport, so drop every earlier copy first.
local function remove_old()
    for _, w in ipairs(FindAllOf("UserWidget") or {}) do
        if w:GetFName():ToString():find(WIDGET_NAME, 1, true) then
            pcall(function() w:RemoveFromParent() end)
        end
    end
end

local function build()
    remove_old()
    local gi = FindFirstOf("GameInstance")
    if not valid(gi) then return nil end
    local widget = new("/Script/UMG.UserWidget", gi, WIDGET_NAME)
    local tree = new("/Script/UMG.WidgetTree", widget, "PartyHudTree")
    widget.WidgetTree = tree
    local canvas = new("/Script/UMG.CanvasPanel", tree, "PartyHudCanvas")
    tree.RootWidget = canvas
    local box = new("/Script/UMG.VerticalBox", tree, "PartyHudBox")
    local slot = canvas:AddChildToCanvas(box)
    slot:SetPosition({ X = CFG.x, Y = CFG.y })
    slot:SetAutoSize(true)
    widget:AddToViewport(50)
    if not visible then widget:SetVisibility(1) end
    return { widget = widget, tree = tree, box = box, rows = {}, order = "" }
end

local function new_row(name)
    local id = string.format("PartyHudRow_%d", math.random(0, 1e9))
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

local function show(row, name, hp, max, fighting)
    local state = hp <= 0 and "dead" or (fighting and "combat" or "normal")
    local text
    if state == "dead" then
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
    row.bar:SetPercent(max > 0 and math.max(hp, 0) / max or 0)
end

local function local_name()
    local pc = FindFirstOf("PlayerController")
    if valid(pc) and valid(pc.PlayerState) then return fstr(pc.PlayerState.PlayerNamePrivate) end
end

local function update()
    if not hud or not valid(hud.widget) then hud = build() end
    if not hud then return end
    local gs = FindFirstOf("GameStateBase")
    if not valid(gs) then return end
    local me, names = local_name(), {}
    gs.PlayerArray:ForEach(function(_, ref)
        local ps = ref:get()
        local name = fstr(ps.PlayerNamePrivate)
        if name == me then return end
        local p = parts_of(name, ps)
        if not valid(p.set) then return end
        local hp, max = p.set.Health.CurrentValue, p.set.MaxHealth.CurrentValue
        names[#names + 1] = name
        if not hud.rows[name] then new_row(name) end
        show(hud.rows[name], name, hp, max, in_combat(name, hp, p.asc))
    end)
    local present = {}
    for _, n in ipairs(names) do present[n] = true end
    for name in pairs(hud.rows) do
        if not present[name] then hud.rows[name], fight[name], lookup[name] = nil, nil, nil end
    end
    arrange(names)
end

RegisterKeyBind(Key[CFG.toggle_key] or Key.F9, function()
    visible = not visible
    ExecuteInGameThread(function()
        if hud and valid(hud.widget) then
            -- ESlateVisibility: 1 = Collapsed, 3 = HitTestInvisible
            hud.widget:SetVisibility(visible and 3 or 1)
        end
    end)
end)

LoopAsync(UPDATE_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(update)
        if not ok then print("[PartyHud] " .. tostring(err) .. "\n") end
    end)
    return false
end)

print(string.format("[PartyHud] loaded (%s), %s toggles the panel\n",
    ok_cfg and "config.lua" or "defaults: " .. tostring(user_cfg), CFG.toggle_key))
