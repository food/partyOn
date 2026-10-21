-- Windrose Party On, server part: shared map markers (markersync.dll + live.lua) and revive
-- (revive.lua). Data files keep their old names in windrose_plus_data (markersync_*.txt,
-- partyrevive.log).
local API = WindrosePlus.API
local DIR = "Z:/home/steam/server-files/windrose_plus_mods/partyon/"

local f, err = package.loadlib(DIR .. "markersync.dll", "*")
API.log("info", "partyon", "loadlib markersync.dll: " .. tostring(f) .. " " .. tostring(err))

dofile(DIR .. "live.lua")
dofile(DIR .. "revive.lua")
