local API = WindrosePlus.API
local dll = "Z:/home/steam/server-files/windrose_plus_mods/markersync/markersync.dll"
local f, err = package.loadlib(dll, "*")
API.log("info", "markersync", "loadlib: " .. tostring(f) .. " " .. tostring(err))
