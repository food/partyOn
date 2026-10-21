-- PartyHud settings. Changes take effect after a hot reload (Ctrl+R) or a game restart.
-- Key names come from UE4SS's Key table (F1..F12, A..Z, NUM_ONE, ...).
return {
    x = 40,              -- panel position from the top left corner, in screen pixels
    y = 300,
    scale = 1.0,         -- text and bar size
    combat_seconds = 10, -- how long a player counts as fighting after losing health
    toggle_key = "F9",   -- hide and show the panel

    -- Revive (needs the server mod partyrevive)
    key_respawn = "F5",  -- after death: respawn at the save point as usual
    key_wait = "F6",     -- after death: wait as a ghost for a teammate
    key_cancel = "F5",   -- as a ghost: give up and respawn at the save point
    key_help = "F7",     -- near a ghost's death spot: revive him there

    -- What marks a ghost's death spot for everyone: "fire" (the game's signal fire, tinted)
    -- or "pillar" (a red column 200 m high)
    marker = "fire",
    fire_color = { R = 0, G = 1, B = 0, A = 1 },
    fire_scale = 1.0,
}
