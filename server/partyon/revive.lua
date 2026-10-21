-- Party On revive: a dead player can wait as a ghost for a teammate instead of respawning.
--
-- The game's own revive is left alone: the player dies and gets a new pawn at his save point
-- 5 s later. If he chose to wait, that new pawn is moved back above his death spot and made a
-- ghost (hidden, no collision, no damage, frozen). Mobs keep attacking a ghost on the ground,
-- so it hangs HOVER cm up where they give up. A teammate within RADIUS of the death spot puts
-- it down there and the player plays on; cancel sends it back to the save point.
--
-- Clients talk to this mod through PlayerController:ServerExecRPC (does nothing else in
-- shipping builds): "partyon wait|respawn|cancel|help". Clients see a ghost by its replicated
-- bHidden flag. Pawn changes run queued on the game thread from client RPC hooks, because
-- Windrose+ runs with HookEngineTick=0.
--
-- RCON: wp.rev status | wp.rev ghost <name> (ghost where he stands, for tests with the bot)
--       | wp.rev free <name> (put a ghost down where he died)
local API = WindrosePlus.API
local LOG = "Z:/home/steam/server-files/windrose_plus_data/partyrevive.log"
local HOVER = 1500        -- cm above the death spot
local RADIUS = 500        -- cm, helper to death spot, horizontal
local RADIUS_Z = 400      -- cm, helper to death spot, vertical
local LATE_WAIT = 20      -- s after death in which "wait" is still accepted

local logf = io.open(LOG, "a")
local function log(fmt, ...)
    logf:write(os.date("!%H:%M:%S "), string.format(fmt, ...), "\n")
    logf:flush()
end

local function valid(o)
    return o ~= nil and o:IsValid()
end

local function vec(l)
    return { X = l.X, Y = l.Y, Z = l.Z }
end

local players = {}   -- [name] = { death, dead_pawn, died_at, want_ghost, back }

local function state(name)
    players[name] = players[name] or {}
    return players[name]
end

local function name_of(ps)
    local ok, n = pcall(function() return ps.PlayerNamePrivate:ToString() end)
    return ok and n or nil
end

-- Active PlayerState by player name, from GameState.PlayerArray (covers the test bot). Not
-- FindAllOf: after a reconnect the old PlayerState stays around without a pawn.
local function find_ps(name)
    local gs = FindFirstOf("GameStateBase")
    if not valid(gs) then return nil end
    local found
    gs.PlayerArray:ForEach(function(_, ref)
        local ps = ref:get()
        if not found and valid(ps) and name_of(ps) == name then found = ps end
    end)
    return found
end

local function pawn_of(ps)
    local ok, p = pcall(function() return ps:GetPawn() end)
    if ok and valid(p) then return p end
end

local function revive_component(ps)
    local path = ps:GetFullName():match("^%S+ (.+)$")
    for _, c in ipairs(FindAllOf("R5ReviveComponent") or {}) do
        if c:GetOwner():IsValid() and c:GetOwner():GetFullName():match("^%S+ (.+)$") == path then return c end
    end
end

-- Hidden, no collision, no damage and frozen while on; the game's periodic location save is
-- locked so a ghost that logs out does not come back in the air.
local function set_ghost(ps, pawn, on)
    local steps = {
        function() pawn:SetActorHiddenInGame(on) end,
        function() pawn:SetActorEnableCollision(not on) end,
        function() pawn.bCanBeDamaged = not on end,
        function()
            if on then pawn.CharacterMovement:DisableMovement() else pawn.CharacterMovement:SetMovementMode(1, 0) end
        end,
        function() revive_component(ps):SetLockLastLocationSave(on) end,
    }
    for i, s in ipairs(steps) do
        local ok, err = pcall(s)
        if not ok then log("set_ghost step %d failed: %s", i, tostring(err)) end
    end
end

local function is_ghost(name)
    return players[name] ~= nil and players[name].back ~= nil
end

local function make_ghost(name)
    local s, ps = state(name), find_ps(name)
    local pawn = ps and pawn_of(ps)
    if not pawn or not s.death then return log("ghost %s: no pawn or no death spot", name) end
    if is_ghost(name) then return end
    s.back = vec(pawn:K2_GetActorLocation())
    s.want_ghost = nil
    local up = { X = s.death.X, Y = s.death.Y, Z = s.death.Z + HOVER }
    pawn:K2_TeleportTo(up, pawn:K2_GetActorRotation())
    set_ghost(ps, pawn, true)
    log("ghost %s above %.0f %.0f %.0f (%s)", name, s.death.X, s.death.Y, s.death.Z, pawn:GetFullName())
end

-- Ends the ghost state at `to` (death spot on help, save point on cancel).
local function end_ghost(name, to, why)
    local s, ps = state(name), find_ps(name)
    local pawn = ps and pawn_of(ps)
    if not pawn or not is_ghost(name) then return end
    pawn:K2_TeleportTo(to, pawn:K2_GetActorRotation())
    set_ghost(ps, pawn, false)
    s.back = nil
    log("%s %s at %.0f %.0f %.0f", why, name, to.X, to.Y, to.Z)
end

local function on_ground(death)
    return { X = death.X, Y = death.Y, Z = death.Z + 100 }
end

-- Nearest ghost whose death spot is within reach of the helper's pawn.
local function help(helper)
    local ps = find_ps(helper)
    local pawn = ps and pawn_of(ps)
    if not pawn or is_ghost(helper) then return log("help from %s: no pawn or helper is a ghost", helper) end
    local h = pawn:K2_GetActorLocation()
    local best, best_d
    for name, s in pairs(players) do
        if name ~= helper and s.back and s.death then
            local dx, dy, dz = s.death.X - h.X, s.death.Y - h.Y, s.death.Z - h.Z
            local d = math.sqrt(dx * dx + dy * dy)
            if d <= RADIUS and math.abs(dz) <= RADIUS_Z and (not best_d or d < best_d) then
                best, best_d = name, d
            end
        end
    end
    if not best then return log("help from %s: no ghost in reach", helper) end
    end_ghost(best, on_ground(players[best].death), "revived by " .. helper .. ":")
end

local queue = {}
local function push(job) queue[#queue + 1] = job end

-- A player who chose to wait becomes a ghost as soon as he has a pawn that is not the dead one.
-- Polled from the tick: the possession hook came too early or not at all when "wait" was picked
-- before the respawn (21.10.2026).
local function ghost_pending()
    for name, s in pairs(players) do
        if s.want_ghost and not s.back then
            if os.time() - (s.died_at or 0) > LATE_WAIT + 30 then
                s.want_ghost = nil
                log("ghost %s: gave up, no respawned pawn", name)
            else
                -- Only a player character counts; the death camera may use another pawn class.
                local ps = find_ps(name)
                local p = ps and pawn_of(ps)
                if p and p:GetFullName() ~= s.dead_pawn and p:GetClass():GetFName():ToString():find("R5Character", 1, true) then
                    make_ghost(name)
                end
            end
        end
    end
end

local function tick()
    local jobs = queue
    queue = {}
    for _, job in ipairs(jobs) do
        local ok, err = pcall(job)
        if not ok then log("job failed: %s", tostring(err)) end
    end
    local ok, err = pcall(ghost_pending)
    if not ok then log("ghost_pending failed: %s", tostring(err)) end
end
RegisterHook("/Script/Engine.Character:ServerMovePacked", tick)
RegisterHook("/Script/Engine.PlayerController:ServerUpdateCamera", tick)

RegisterHook("/Script/R5.R5ReviveComponent:OnPawnDead", function(self, actor)
    pcall(function()
        local name = name_of(self:get():GetOwner())
        local s, dead = state(name), actor:get()
        s.death = vec(dead:K2_GetActorLocation())
        s.dead_pawn = dead:GetFullName()
        s.died_at, s.back, s.want_ghost = os.time(), nil, nil
        log("death %s at %.0f %.0f %.0f", name, s.death.X, s.death.Y, s.death.Z)
    end)
end)

RegisterHook("/Script/Engine.PlayerController:ServerExecRPC", function(self, msg)
    local ok, text, name = pcall(function()
        return msg:get():ToString(), name_of(self:get().PlayerState)
    end)
    if not ok or not name then return end
    local cmd = text:match("^partyon (%a+)")
    if not cmd then return end
    log("message %s from %s", cmd, name)
    local s = state(name)
    if cmd == "wait" then
        if not s.died_at or os.time() - s.died_at > LATE_WAIT then return end
        s.want_ghost = true
    elseif cmd == "respawn" then
        s.want_ghost = nil
    elseif cmd == "cancel" then
        push(function() if s.back then end_ghost(name, s.back, "cancel") end end)
    elseif cmd == "help" then
        push(function() help(name) end)
    end
end)

local ops = {}

function ops.status()
    local out = {}
    for name, s in pairs(players) do
        out[#out + 1] = string.format("%s: %s%s", name, s.back and "ghost" or "alive",
            s.death and string.format(", died at %.0f %.0f %.0f", s.death.X, s.death.Y, s.death.Z) or "")
    end
    return #out > 0 and table.concat(out, "\n") or "no players tracked"
end

function ops.ghost(name)
    push(function()
        local ps = find_ps(name)
        local p = ps and pawn_of(ps)
        if not p then return log("ghost %s: not found", name) end
        state(name).death = vec(p:K2_GetActorLocation())
        make_ghost(name)
    end)
    return "queued ghost " .. name .. " (runs when a player moves)"
end

function ops.free(name)
    push(function()
        local s = players[name]
        if s and s.back and s.death then end_ghost(name, on_ground(s.death), "freed") end
    end)
    return "queued free " .. name .. " (runs when a player moves)"
end

API.registerCommand("wp.rev", function(args)
    local op = ops[args[1] or ""]
    if not op then return "usage: wp.rev status | ghost <name> | free <name>" end
    return op(table.concat(args, " ", 2))
end, "Party revive", "wp.rev status|ghost <name>|free <name>")

log("revive loaded")
