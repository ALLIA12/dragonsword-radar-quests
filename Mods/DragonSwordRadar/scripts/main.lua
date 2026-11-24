-- DragonSword Radar: chest and quest markers on the minimap and world map.
-- F8 shows/hides all markers, F9 shows/hides quest markers.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\][Ss]cripts[/\\][^/\\]+$")
local function log(msg) print("[DSRadar] " .. tostring(msg) .. "\n") end
if not root then log("cannot locate the mod folder") return end

-- The native helper reads chest locations from the game files and progress from the save.
local dll = root .. "\\dsradar.dll"
local start, err = package.loadlib(dll, "dsradar_start")
local ping = package.loadlib(dll, "dsradar_ping")
if start then start() else log("native helper not loaded, chest markers are off: " .. tostring(err)) end

local quests = dofile(root .. "\\scripts\\quests.lua")(log)
local radar = dofile(root .. "\\scripts\\radar.lua")(root, log, quests)

local show_all, show_quests = true, true
RegisterKeyBind(Key.F8, function()
    if generation ~= _G.DSRadarGeneration then return end
    show_all = not show_all
    log(show_all and "Markers shown" or "Markers hidden")
end)
RegisterKeyBind(Key.F9, function()
    if generation ~= _G.DSRadarGeneration then return end
    show_quests = not show_quests
    log(show_quests and "Quest markers shown" or "Quest markers hidden")
end)

-- A reload (UE4SS hot reload) starts a new generation; the old loop then stops itself.
_G.DSRadarGeneration = (_G.DSRadarGeneration or 0) + 1
local generation = _G.DSRadarGeneration

local busy, ticks = false, 0
LoopAsync(50, function()
    if generation ~= _G.DSRadarGeneration then pcall(radar.hide_all) return true end
    if busy then return false end
    busy = true
    ExecuteInGameThread(function()
        local ok, e = pcall(radar.update, show_all, show_quests)
        if not ok then radar.fail(e) end
        ticks = ticks + 1
        -- Tells the helper a save is loaded, which is when the save key can be found.
        if ping and ticks % 40 == 0 and radar.in_world() then pcall(ping) end
        busy = false
    end)
    return false
end)
log("DragonSword Radar loaded. F8: all markers, F9: quest markers.")
