-- Draws chest and quest markers on the minimap and the world map.
--
-- Markers live in a CanvasPanel added next to each map layer's overlay. The canvas is shifted so
-- that canvas coordinates are world coordinates scaled by the map's UI scale, which keeps the
-- per-marker work to one SetPosition call when the map moves.
return function(root, log, quests)
    local R = {}
    local MINIMAP_RADIUS = 160          -- px around the player shown on the minimap
    local MAX_NEW_WIDGETS = 32          -- per tick, to avoid hitches when a map opens
    local COLORS = {
        white  = {R = 1.00, G = 1.00, B = 1.00, A = 1},
        orange = {R = 1.00, G = 0.45, B = 0.05, A = 1},
        green  = {R = 0.20, G = 0.95, B = 0.35, A = 1},
        plain  = {R = 1.00, G = 1.00, B = 1.00, A = 1},
    }

    local tick, failed_with = 0, nil
    local engine, layout, image_class, canvas_class, importer
    local textures, layers, map_info = {}, {}, {}
    local chests, chests_version, chests_by_map = nil, nil, {}
    local state, state_text, state_revision = {opened = {}, quests_done = {}}, nil, 0
    local pawn_name, in_world = nil, false

    local events = _G.DSRadarEvents
    if not events then
        events = {dirty = true}
        _G.DSRadarEvents = events
        NotifyOnNewObject("/Script/DSClient.DLayerMap", function() events.dirty = true end)
        NotifyOnNewObject("/Script/DSClient.DWorldMapData", function() events.dirty = true end)
    end

    local function valid(o)
        local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
        return ok and v
    end
    local function full_name(o) return valid(o) and o:GetFullName() or "" end
    local function read(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local t = f:read("*a") f:close()
        return t
    end
    local function eval(text)
        local fn = text and load(text, "data", "t", {})
        local ok, v = pcall(function() return fn and fn() end)
        return ok and type(v) == "table" and v or nil
    end

    -- ------------------------------------------------------------------ data from the helper

    local function refresh_chests()
        local version = read(root .. "\\cache\\catalog.version")
        if version == chests_version and chests then return end
        local data = eval(read(root .. "\\cache\\treasures.lua"))
        if not data or type(data.list) ~= "table" then return end
        chests_version, chests, chests_by_map = version, data.list, {}
        for _, c in ipairs(data.list) do
            c.color = c.kind == "minigame" and "green" or c.kind == "map" and "orange" or "white"
            chests_by_map[c.map] = chests_by_map[c.map] or {}
            table.insert(chests_by_map[c.map], c)
        end
        state_revision = state_revision + 1
        log("Treasure catalog loaded: " .. #data.list .. " chests")
    end

    local function refresh_state()
        local text = read(root .. "\\cache\\state.lua")
        if text == state_text then return end
        state_text = text
        local data = eval(text)
        if data and type(data.opened) == "table" then
            state = {opened = data.opened, quests_done = data.quests_done or {}, ready = true}
            state_revision = state_revision + 1
        end
    end

    -- ------------------------------------------------------------------ map settings

    local function load_map_info()
        local data = eval(read(root .. "\\cache\\maps.lua"))
        if data then map_info = data end
    end
    local function save_map_info()
        local rows = {"return {"}
        for id, m in pairs(map_info) do
            rows[#rows + 1] = string.format("[%d]={size=%.9g,mini=%.9g,dim=%.9g,cx=%.9g,cy=%.9g},", id, m.size, m.mini, m.dim, m.cx, m.cy)
        end
        rows[#rows + 1] = "}"
        local f = io.open(root .. "\\cache\\maps.lua", "w")
        if f then f:write(table.concat(rows, "\n")) f:close() end
    end
    local function map_objects()
        local list = FindAllOf("DWorldMapData") or {}
        -- Load the map settings assets up front so markers work before the world map is opened.
        if chests and not R.preloaded then
            R.preloaded = true
            local ids = {}
            for id in pairs(chests_by_map) do ids[id] = true end
            for id = 100, 900, 100 do ids[id] = true end
            for id in pairs(ids) do
                if not map_info[id] then
                    local path = string.format("/Game/Design/CaptureMinimap/Data/WorldMapData_%d.WorldMapData_%d", id, id)
                    pcall(LoadAsset, path)
                    local ok, obj = pcall(StaticFindObject, path)
                    if ok and valid(obj) then list[#list + 1] = obj end
                end
            end
        end
        return list
    end
    local function scan_maps()
        local changed = false
        for _, obj in ipairs(map_objects()) do
            if valid(obj) then
                local i = obj.WorldMapDataInfo
                local id = tonumber(i.MapID)
                local m = {size = tonumber(i.WorldMapUISize), mini = tonumber(i.MiniMapUISize), dim = tonumber(i.MapDimensions),
                           cx = tonumber(i.MapDimensionsCenterX), cy = tonumber(i.MapDimensionsCenterY)}
                if id and id > 0 and m.dim and m.dim > 0 and m.size and m.size > 0 and m.mini and m.mini > 0 then
                    local o = map_info[id]
                    if not o or o.size ~= m.size or o.mini ~= m.mini or o.dim ~= m.dim or o.cx ~= m.cx or o.cy ~= m.cy then
                        map_info[id] = m changed = true
                    end
                end
            end
        end
        if changed then save_map_info() end
        for _, layer in ipairs(FindAllOf("DLayerMap") or {}) do
            local n = full_name(layer)
            if n:find("/Engine/Transient", 1, true) and not layers[n] then
                layers[n] = {layer = layer, pool = {}, mini = n:find("DLayerMiniMap", 1, true) ~= nil}
            end
        end
    end
    -- "world_01" / "_w1_" style names -> map id 100, 200, ...
    local function map_id_from(text)
        text = text:lower()
        local n = text:match("world_0*(%d+)") or text:match("_w(%d+)_")
        return n and tonumber(n) * 100 or nil
    end

    -- ------------------------------------------------------------------ widgets

    local function texture(name, context)
        if not valid(textures[name]) then
            if not valid(importer) then importer = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary") end
            textures[name] = importer:ImportFileAsTexture2D(context, root .. "\\assets\\" .. name .. ".png")
            assert(valid(textures[name]), "could not load icon " .. name)
        end
        return textures[name]
    end
    local function new_image(parent)
        if not valid(image_class) then image_class = StaticFindObject("/Script/UMG.Image") end
        local w = StaticConstructObject(image_class, parent)
        assert(valid(w), "could not create a marker")
        w:SetVisibility(2)
        local slot = parent:AddChild(w)
        slot:SetAutoSize(false)
        slot:SetAnchors({Minimum = {X = 0, Y = 0}, Maximum = {X = 0, Y = 0}})
        slot:SetAlignment({X = 0.5, Y = 0.5})
        return {w = w, slot = slot}
    end
    local function show(it, m, context)
        if it.icon ~= m.icon then it.w:SetBrushFromTexture(texture(m.icon, context), false) it.icon = m.icon end
        if it.color ~= m.color then it.w:SetColorAndOpacity(COLORS[m.color]) it.color = m.color end
        if it.size ~= m.size then it.slot:SetSize({X = m.size, Y = m.size}) it.size = m.size end
        if it.x ~= m.px or it.y ~= m.py then it.slot:SetPosition({X = m.px, Y = m.py}) it.x, it.y = m.px, m.py end
        if it.z ~= m.z_order then it.slot:SetZOrder(m.z_order) it.z = m.z_order end
        if it.angle ~= m.angle then it.w:SetRenderTransformAngle(m.angle) it.angle = m.angle end
        if not it.visible then it.w:SetVisibility(3) it.visible = true end
    end
    local function hide_from(entry, first)
        for i = first, #entry.pool do
            local it = entry.pool[i]
            if it.visible and valid(it.w) then it.w:SetVisibility(2) it.visible = false end
        end
    end
    local function hide(entry) hide_from(entry, 1) entry.stamp = nil end

    function R.hide_all() for _, e in pairs(layers) do pcall(hide, e) end end
    local function clear()
        for _, e in pairs(layers) do
            for _, it in ipairs(e.pool) do if valid(it.w) then pcall(function() it.w:RemoveFromParent() end) end end
            if valid(e.canvas) then pcall(function() e.canvas:RemoveFromParent() end) end
        end
        layers = {}
        events.dirty = true
    end

    -- ------------------------------------------------------------------ drawing one map layer

    local function draw(entry, id, info, pos, view_w, view_h, show_quests)
        local layer = entry.layer
        local scale = layer.MapOverlay.RenderTransform.Scale.X
        local origin = layer.MapOverlaySlot:GetPosition()
        local content = layer.MapOverlayOutSideSlot:GetSize()
        local stamp = table.concat({id, state_revision, quests.revision, tostring(show_quests), origin.X, origin.Y, content.X, content.Y, scale,
            view_w, view_h, math.floor(pos.X / 10), math.floor(pos.Y / 10), math.floor(pos.Z / 25)}, ":")
        if stamp == entry.stamp then return end

        if not valid(entry.canvas) then
            if not valid(canvas_class) then canvas_class = StaticFindObject("/Script/UMG.CanvasPanel") end
            local host = layer.MapOverlayOutSide:GetParent()
            local c = StaticConstructObject(canvas_class, host)
            assert(valid(c), "could not create the marker canvas")
            c:SetVisibility(3)
            local slot = host:AddChild(c)
            slot:SetAutoSize(false)
            slot:SetAnchors({Minimum = {X = 0, Y = 0}, Maximum = {X = 0, Y = 0}})
            slot:SetAlignment({X = 0, Y = 0})
            slot:SetPosition({X = 0, Y = 0})
            slot:SetZOrder(100)
            entry.canvas, entry.canvas_slot, entry.pool = c, slot, {}
        end
        if entry.w ~= view_w or entry.h ~= view_h then
            entry.canvas_slot:SetSize({X = view_w, Y = view_h})
            entry.w, entry.h = view_w, view_h
        end

        local k = (entry.mini and info.mini or info.size) / info.dim * scale
        local ox = origin.X + content.X * 0.5 * scale - info.cx * k
        local oy = origin.Y + content.Y * 0.5 * scale - info.cy * k
        if entry.ox ~= ox or entry.oy ~= oy then
            entry.canvas:SetRenderTranslation({X = ox, Y = oy})
            entry.ox, entry.oy = ox, oy
        end

        local function visible(x, y)
            if entry.mini then
                local dx, dy = (x - pos.X) * k, (y - pos.Y) * k
                return dx * dx + dy * dy < MINIMAP_RADIUS * MINIMAP_RADIUS
            end
            local sx, sy = ox + x * k, oy + y * k
            return sx >= -12 and sy >= -12 and sx <= view_w + 12 and sy <= view_h + 12
        end

        local list, nearest, nearest_d = {}, nil, math.huge
        if state.ready then
            for _, c in ipairs(chests_by_map[id] or {}) do
                if not state.opened[c.id] and visible(c.x, c.y) then
                    local m = {px = c.x * k, py = c.y * k, icon = "dot", color = c.color, size = 16, z_order = 100, angle = 0}
                    list[#list + 1] = m
                    local d = (c.x - pos.X) ^ 2 + (c.y - pos.Y) ^ 2
                    if d < nearest_d then nearest, nearest_d, m.chest = m, d, c end
                end
            end
        end
        if nearest then
            nearest.icon, nearest.size = "dot-near", 22
            local c = nearest.chest
            local dz = c.z - (pos.Z - 100)
            if math.abs(dz) > 100 then
                list[#list + 1] = {px = nearest.px - 22, py = nearest.py, icon = "arrow", color = nearest.color, size = 40, z_order = 103, angle = dz > 0 and -90 or 90}
            end
        end
        if show_quests then
            for _, q in ipairs(quests.on_map(id)) do
                if q.active and visible(q.x, q.y) then
                    list[#list + 1] = q.kind == "quest"
                        and {px = q.x * k, py = q.y * k, icon = "quest", color = "plain", size = 26, z_order = 102, angle = 0}
                        or  {px = q.x * k, py = q.y * k, icon = "talk", color = "plain", size = 22, z_order = 101, angle = 0}
                end
            end
        end

        local made, used, complete = 0, 0, true
        for _, m in ipairs(list) do
            local it = entry.pool[used + 1]
            if not it or not valid(it.w) then
                if made >= MAX_NEW_WIDGETS then complete = false break end
                it = new_image(entry.canvas)
                entry.pool[used + 1] = it
                made = made + 1
            end
            used = used + 1
            show(it, m, layer)
        end
        hide_from(entry, used + 1)
        entry.stamp = complete and stamp or nil
        if complete and used ~= entry.logged and (not entry.logged_at or tick - entry.logged_at > 200) then
            entry.logged, entry.logged_at = used, tick
            log((entry.mini and "Minimap" or "World map") .. ": " .. used .. " markers")
        end
    end

    -- ------------------------------------------------------------------ per tick

    function R.in_world() return in_world end

    function R.fail(err)
        R.hide_all()
        err = tostring(err)
        if err ~= failed_with then log("Radar: " .. err) failed_with = err end
    end

    function R.update(show_all, show_quests)
        tick = tick + 1
        if tick == 1 then load_map_info() end
        if tick == 1 or tick % 200 == 0 then refresh_chests() end
        if tick % 20 == 0 then refresh_state() end

        if not valid(engine) then engine = FindFirstOf("Engine") end
        local ok, pawn = pcall(function() return engine.GameViewport.GameInstance.LocalPlayers[1].PlayerController.Pawn end)
        in_world = ok and valid(pawn)
        if not in_world then R.hide_all() return end
        local name = full_name(pawn)
        if name ~= pawn_name then clear() pawn_name = name end

        -- Random quests wait for the save to be read, so finished ones never flash up; if the
        -- helper cannot read the save they appear after two minutes regardless.
        local finished = state.ready and state.quests_done or (tick > 2400 and {} or nil)
        quests.update(pawn, finished)
        if not show_all then R.hide_all() return end

        if events.dirty or tick % 1500 == 0 or (chests and not R.preloaded) then events.dirty = false scan_maps() end
        if not valid(layout) then layout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
        local size = layout:GetViewportSize(pawn)
        local dpi = layout:GetViewportScale(pawn)
        local view_w, view_h = size.X / dpi, size.Y / dpi
        local pos = pawn:K2_GetActorLocation()

        for key, entry in pairs(layers) do
            if not valid(entry.layer) then layers[key] = nil
            elseif not entry.layer:IsVisible() then if entry.stamp then hide(entry) end
            else
                local id = entry.mini and map_id_from(name) or map_id_from(full_name(entry.layer.Map_0_0.Brush.ResourceObject))
                local info = id and map_info[id]
                if info then draw(entry, id, info, pos, view_w, view_h, show_quests) elseif entry.stamp then hide(entry) end
            end
        end
        failed_with = nil
    end

    return R
end
