-- PartyHud: a panel with name and health bar for every other player on the server.
-- Built from plain UMG classes at runtime, so no cooked widget blueprint is needed.
-- Health comes from the R5AttributeSet on each PlayerState, which every client receives.
-- F9 toggles the panel.

local POS = { X = 40, Y = 300 }   -- panel position on screen
local BAR = { W = 220, H = 10 }
local UPDATE_MS = 250
local WIDGET_NAME = "PartyHudWidget"

local hud = nil       -- { widget, box, rows = { [name] = { label, bar } } }
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

local function attribute_set_of(ps)
    local path = ps:GetFullName():match("^%S+ (.+)$")
    for _, set in ipairs(FindAllOf("R5AttributeSet") or {}) do
        local outer = set:GetOuter()
        if outer:IsValid() and outer:GetFullName():match("^%S+ (.+)$") == path then return set end
    end
end

local function health(ps)
    local set = attribute_set_of(ps)
    if not set then return nil end
    return set.Health.CurrentValue, set.MaxHealth.CurrentValue
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
    slot:SetPosition(POS)
    slot:SetAutoSize(true)
    widget:AddToViewport(50)
    return { widget = widget, tree = tree, box = box, rows = {} }
end

local function add_row(name)
    local n = 0
    for _ in pairs(hud.rows) do n = n + 1 end
    local id = string.format("PartyHudRow%d_%d", n, math.random(0, 1e6))
    local label = new("/Script/UMG.TextBlock", hud.tree, id .. "Label")
    pcall(function()
        local font = label.Font
        font.Size = 14
        label:SetFont(font)
    end)
    label:SetShadowOffset({ X = 1, Y = 1 })
    label:SetShadowColorAndOpacity({ R = 0, G = 0, B = 0, A = 0.8 })
    local size = new("/Script/UMG.SizeBox", hud.tree, id .. "Size")
    size:SetWidthOverride(BAR.W)
    size:SetHeightOverride(BAR.H)
    local bar = new("/Script/UMG.ProgressBar", hud.tree, id .. "Bar")
    bar:SetFillColorAndOpacity({ R = 0.75, G = 0.12, B = 0.12, A = 1 })
    size:AddChild(bar)
    hud.box:AddChildToVerticalBox(label)
    local s = hud.box:AddChildToVerticalBox(size)
    s:SetPadding({ Left = 0, Top = 2, Right = 0, Bottom = 8 })
    hud.rows[name] = { label = label, size = size, bar = bar }
end

local function remove_row(name)
    local row = hud.rows[name]
    pcall(function() row.label:RemoveFromParent() end)
    pcall(function() row.size:RemoveFromParent() end)
    hud.rows[name] = nil
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
    local me, seen = local_name(), {}
    gs.PlayerArray:ForEach(function(_, ref)
        local ps = ref:get()
        local name = fstr(ps.PlayerNamePrivate)
        if name == me then return end
        local hp, max = health(ps)
        if not hp then return end
        seen[name] = true
        if not hud.rows[name] then add_row(name) end
        local row = hud.rows[name]
        row.label:SetText(FText(string.format("%s  %.0f / %.0f", name, hp, max)))
        row.bar:SetPercent(max > 0 and hp / max or 0)
    end)
    for name in pairs(hud.rows) do
        if not seen[name] then remove_row(name) end
    end
end

RegisterKeyBind(Key.F9, function()
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

print("[PartyHud] loaded, F9 toggles the panel\n")
