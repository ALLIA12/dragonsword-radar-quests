return function(root, log)
    local R = {}
    local layers, points, maps = {}, nil, {}
    local engine, image_class, canvas_class, importer, layout
    local textures, by_map, opened, state_text = {}, {}, {}, nil
    local ready, state_revision, last_enabled = false, 0, true
    local events = _G.TreasureNativeEvents
    if not events then
        events = {dirty=true}
        _G.TreasureNativeEvents = events
        NotifyOnNewObject("/Script/DSClient.DLayerMap", function() events.dirty=true end)
        NotifyOnNewObject("/Script/DSClient.DWorldMapData", function() events.dirty=true end)
    end
    events.dirty = true
    local tick, last_error, version, last_pawn = 0, nil, nil, nil
    -- Quest markers (local addition). Two kinds, both read from the game's own tables:
    --   "quest": side quests the game reports as acceptable that start by talking to an NPC
    --   "talk":  random NPC encounters (the NPCs with a "..." bubble) that have not been done yet
    local QUEST_ACCEPT_NPC, QUEST_ACCEPT_INTERACT_NPC = 2, 7      -- EQuestAcceptType
    local QS_NONE, QS_ACCEPTABLE, QS_PROGRESS, QS_END, QS_FAIL = 0, 1, 2, 3, 4    -- DENM_QuestState
    local COND_QUEST_CLEAR = 3                                    -- EConditionType
    local quest_poll, quest_markers, quest_by_map, quest_util = nil, {}, {}, nil
    local quest_state, quest_cursor = {}, 0
    local quest_revision, quest_sig, quest_retry, quest_failures = 0, nil, 0, 0
    local quests_enabled = true
    -- Random NPC quests finished in an earlier session are only recorded in the save file: after a
    -- restart the game's live quest state reports them as never started. quest_state.lua carries that
    -- list. It is filled from the save by sync_completed_quests.ps1 and extended here whenever a
    -- quest is seen finishing, so it stays correct while the radar is running.
    local quest_state_path = root.."\\quest_state.lua"
    local quest_done, quest_done_session = {}, {}
    local function valid(obj)
        local ok, value = pcall(function() return obj ~= nil and obj:IsValid() end)
        return ok and value
    end
    local function name(obj) return valid(obj) and obj:GetFullName() or "" end
    local function load_table(path)
        local f = loadfile(path, "t", {})
        if not f then return nil end
        local ok, value = pcall(f)
        return ok and type(value) == "table" and value or nil
    end
    local function read_version()
        local f = io.open(root.."\\cache\\catalog.version", "r")
        if not f then return nil end
        local value = f:read("*a") f:close() return value
    end
    local function hide(entry)
        for _, item in ipairs(entry.markers) do
            if item.visible and valid(item.widget) then item.widget:SetVisibility(2) item.visible=false end
        end
        if entry.arrow and entry.arrow.visible and valid(entry.arrow.widget) then entry.arrow.widget:SetVisibility(2) entry.arrow.visible=false end
        for _, item in ipairs(entry.qmarkers) do
            if item.visible and valid(item.widget) then item.widget:SetVisibility(2) item.visible=false end
        end
        entry.stamp=nil entry.active=false
    end
    function R.clear()
        for _, entry in pairs(layers) do
            if entry.arrow and valid(entry.arrow.widget) then pcall(function() entry.arrow.widget:RemoveFromParent() end) end
            for _, item in ipairs(entry.markers) do
                if valid(item.widget) then pcall(function() item.widget:RemoveFromParent() end) end
            end
            for _, item in ipairs(entry.qmarkers) do
                if valid(item.widget) then pcall(function() item.widget:RemoveFromParent() end) end
            end
        end
        for _, entry in pairs(layers) do
            if valid(entry.canvas) then pcall(function() entry.canvas:RemoveFromParent() end) end
        end
        layers = {}
        events.dirty = true
    end
    function R.failure(err)
        for _, entry in pairs(layers) do pcall(hide, entry) end
        err = tostring(err)
        if err ~= last_error then log("Renderer: "..err) last_error = err end
    end
    local function save_maps()
        if not version then return end
        local rows = {"return {version="..string.format("%q",version)..",maps={"}
        for id, m in pairs(maps) do
            rows[#rows+1] = string.format("[%d]={size=%.9g,mini=%.9g,dimension=%.9g,cx=%.9g,cy=%.9g},",id,m.size,m.mini,m.dimension,m.cx,m.cy)
        end
        rows[#rows+1] = "}}"
        local f = io.open(root.."\\cache\\maps.lua", "w")
        if f then f:write(table.concat(rows,"\n")) f:close() end
    end
    local function map_id(text)
        text = text:lower()
        local n = text:match("world_0*(%d+)") or text:match("_w(%d+)_")
        return n and tonumber(n)*100 or nil
    end
    local function texture(key, context)
        if not valid(textures[key]) then
            if not valid(importer) then importer=StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary") end
            textures[key]=importer:ImportFileAsTexture2D(context,root.."\\assets\\"..key..".png")
            assert(valid(textures[key]),"Could not import marker texture: "..key)
        end
        return textures[key]
    end
    local function make_marker(parent, zorder)
        if not valid(image_class) then image_class=StaticFindObject("/Script/UMG.Image") end
        local widget=StaticConstructObject(image_class,parent)
        assert(valid(widget),"Could not create marker image")
        widget:SetVisibility(2)
        local slot = parent:AddChild(widget)
        slot:SetAutoSize(false)
        slot:SetAnchors({Minimum={X=0,Y=0},Maximum={X=0,Y=0}})
        slot:SetAlignment({X=0.5,Y=0.5})
        slot:SetZOrder(zorder or 100)
        return {widget=widget,slot=slot}
    end
    -- Builds the list of NPC-given quests and where each one starts. The quest tables are static game
    -- data, so this runs once per session; only the per-quest state is polled afterwards.
    local function load_quests()
        local qtbl, ptbl = FindFirstOf("DQuestDataTable"), FindFirstOf("DActorPositionTable")
        local dtbl = FindFirstOf("DDynamicQuestDataTable")
        if not valid(qtbl) or not valid(ptbl) or not valid(dtbl) then return false end
        local list, by_id = {}, {}
        qtbl.QuestMainDataMap.Data:ForEach(function(k, v)
            local accept = v:get().AcceptType
            if accept == QUEST_ACCEPT_NPC or accept == QUEST_ACCEPT_INTERACT_NPC then
                local c = {id = k:get(), dynamic = false, kind = "quest"}
                list[#list+1] = c by_id[c.id] = c
            end
        end)
        -- Random NPC encounters. Some only unlock after a story quest; that quest's state is polled too.
        local dynamic, required = {}, {}
        dtbl.DynamicQuestMainMap.Data:ForEach(function(_, v)
            v:get().DynamicQuestMainDataMap:ForEach(function(k2, v2)
                local q = v2:get()
                local c = {id = k2:get(), dynamic = true, kind = "talk"}
                if q.AcceptConditionType == COND_QUEST_CLEAR then
                    c.requires = q.AcceptConditionValue1
                    required[c.requires] = true
                end
                list[#list+1] = c dynamic[c.id] = c
            end)
        end)
        -- The first step of an NPC quest is the conversation that starts it.
        local need = {}
        qtbl.QuestStepDataMap.Data:ForEach(function(k, v)
            local c = by_id[k:get()]
            if c then
                local first
                v:get().QuestStepDataArray:ForEach(function(_, el)
                    local s = el:get()
                    local sid = s.StepID
                    if not first or sid < first then first = sid c.pos = s.StepPosition:ToString() c.group = s.IconMapGroupID end
                end)
                if c.pos and c.pos ~= "" then need[c.pos] = true end
            end
        end)
        -- Named positions -> world coordinates. Groups 100, 200, ... are the open-world maps.
        local found = {}
        ptbl.DataMap.Data:ForEach(function(k, v)
            local group = k:get()
            if group % 100 == 0 and group < 10000 then
                v:get().Data:ForEach(function(_, v2)
                    local d = v2:get()
                    local name = d.Name:ToString()
                    if need[name] then
                        found[name] = found[name] or {}
                        found[name][group] = {x = d.PosX, y = d.PosY, z = d.PosZ}
                    else
                        -- Encounter positions are named DQ<quest id>_<step>_<what>; keep the earliest
                        -- real one (helper points such as cameras and move checks rank last).
                        local id, rest = name:match("^DQ(%d+)_(.+)$")
                        local c = id and dynamic[tonumber(id)]
                        if c then
                            local helper = (rest:find("Move_Check", 1, true) or rest:find("Camera", 1, true) or rest:find("Light", 1, true) or rest:find("Empty", 1, true)) and 1 or 0
                            local rank = (tonumber(rest:match("^(%d+)_")) or 0) * 2 + helper
                            if not c.rank or rank < c.rank or (rank == c.rank and name < c.pos) then
                                c.rank, c.pos, c.spot = rank, name, {group = group, x = d.PosX, y = d.PosY, z = d.PosZ}
                            end
                        end
                    end
                end)
            end
        end)
        local markers, by_key, by_group, counts = {}, {}, {}, {quest = 0, talk = 0}
        local function attach(c, group, p)
            local key = c.kind .. ":" .. group .. ":" .. p.x .. ":" .. p.y
            local m = by_key[key]
            if not m then
                m = {x = p.x, y = p.y, z = p.z, kind = c.kind, active = false}
                by_key[key] = m markers[#markers+1] = m
                by_group[group] = by_group[group] or {}
                table.insert(by_group[group], m)
            end
            c.marker = m counts[c.kind] = counts[c.kind] + 1
        end
        local poll = {}
        for _, c in ipairs(list) do
            if c.dynamic then
                if c.spot then attach(c, c.spot.group, c.spot) end
            else
                local f = c.pos and found[c.pos]
                if f then
                    local group = f[c.group] and c.group or next(f)
                    attach(c, group, f[group])
                end
            end
            if c.marker then poll[#poll+1] = c end
        end
        for id in pairs(required) do poll[#poll+1] = {id = id, dynamic = false} end
        quest_poll, quest_markers, quest_by_map = poll, markers, by_group
        quest_sig, quest_cursor, quest_state = nil, 0, {}
        log("Quest catalog indexed: " .. counts.quest .. " NPC quests, " .. counts.talk .. " NPC encounters, " .. #markers .. " locations")
        return true
    end
    local function read_quest_done()
        local data = load_table(quest_state_path)
        local done = {}
        if data and type(data.done) == "table" then
            for id, v in pairs(data.done) do if v and type(id) == "number" then done[id] = true end end
        end
        return done
    end
    local function write_quest_done(done)
        local ids = {}
        for id in pairs(done) do ids[#ids+1] = id end
        table.sort(ids)
        local rows = {"-- Random NPC quests known to be completed. Maintained by the radar; see sync_completed_quests.ps1.", "return {done={"}
        for _, id in ipairs(ids) do rows[#rows+1] = string.format("[%d]=true,", id) end
        rows[#rows+1] = "}}"
        local f = io.open(quest_state_path, "w")
        if f then f:write(table.concat(rows, "\n")) f:close() end
    end
    -- Brings the completed list up to date after a full pass over the quest states.
    local function update_quest_done()
        quest_done = read_quest_done()
        local dirty, conflict = false, false
        for _, q in ipairs(quest_poll) do
            if q.dynamic then
                if q.state == QS_END then
                    quest_done_session[q.id] = true
                elseif q.state == QS_PROGRESS and quest_done[q.id] and not quest_done_session[q.id] then
                    conflict = true
                end
            end
        end
        if conflict then
            -- A quest listed as completed is in progress, so the list belongs to a different save.
            quest_done, dirty = {}, true
            log("Quest markers: the completed-quest list did not match this save and was reset")
        end
        for id in pairs(quest_done_session) do
            if not quest_done[id] then quest_done[id] = true dirty = true end
        end
        if dirty then write_quest_done(quest_done) end
    end
    -- Checks a few quests per call so the cost is spread out; markers update after each full pass.
    local function poll_quests(context)
        if not valid(quest_util) then quest_util = StaticFindObject("/Script/DS.Default__DETUtil") end
        local total = #quest_poll
        for _ = 1, math.min(8, total) do
            quest_cursor = quest_cursor + 1
            local c = quest_poll[quest_cursor]
            local step, current, max, state = {}, {}, {}, {}
            quest_util:GetQuestInfoInStandAlone(context, c.id, c.dynamic, step, current, max, state)
            c.state = state.QuestState
            if not c.dynamic then quest_state[c.id] = c.state end
            if quest_cursor >= total then
                quest_cursor = 0
                update_quest_done()
                for _, m in ipairs(quest_markers) do m.want = false end
                local ids = {}
                for _, q in ipairs(quest_poll) do
                    if q.marker then
                        local on
                        if q.dynamic then
                            on = (q.state == QS_NONE or q.state == QS_FAIL) and not quest_done[q.id] and (not q.requires or quest_state[q.requires] == QS_END)
                        else
                            on = q.state == QS_ACCEPTABLE
                        end
                        if on then q.marker.want = true ids[#ids+1] = q.id end
                    end
                end
                local sig = table.concat(ids, ",")
                if sig ~= quest_sig then
                    quest_sig = sig
                    local shown = {quest = 0, talk = 0}
                    for _, m in ipairs(quest_markers) do
                        m.active = m.want
                        if m.active then shown[m.kind] = shown[m.kind] + 1 end
                    end
                    quest_revision = quest_revision + 1
                    log("Quest markers: " .. shown.quest .. " NPC quests, " .. shown.talk .. " NPC encounters available")
                end
                break
            end
        end
    end
    function R.toggle_quests()
        quests_enabled = not quests_enabled
        quest_revision = quest_revision + 1
        log(quests_enabled and "Quest markers enabled" or "Quest markers hidden")
    end
    local function place(item,x,y,key,size,angle,context)
        if item.key~=key then item.widget:SetBrushFromTexture(texture(key,context),false) item.key=key end
        if item.size~=size then item.slot:SetSize({X=size,Y=size}) item.size=size end
        if item.x~=x or item.y~=y then item.slot:SetPosition({X=x,Y=y}) item.x=x item.y=y end
        if item.angle~=angle then item.widget:SetRenderTransformAngle(angle) item.angle=angle end
        if not item.visible then item.widget:SetVisibility(3) item.visible=true end
    end
    function R.update(enabled)
        tick=tick+1
        if tick==1 or tick%250==0 then
            local current=read_version()
            if current~=version then
                R.clear() points=nil maps={} version=current
                local cached=load_table(root.."\\cache\\maps.lua")
                if cached and cached.version==version and type(cached.maps)=="table" then maps=cached.maps end
            end
        end
        if not points then
            points=load_table(root.."\\cache\\treasures.lua")
            if not points then return end
            by_map={}
            for _,p in ipairs(points) do
                local id=tonumber(tostring(p.section):sub(-3))
                if id then
                    local kind=(p.uid_name or ""):match("^DT_([A-Za-z]+)_G%d+_")
                    kind=kind and kind:lower() or ""
                    p.color=kind=="minigame" and "green" or kind=="map" and "orange" or "white"
                    by_map[id]=by_map[id] or {} table.insert(by_map[id],p)
                end
            end
            log("Catalog indexed: "..#points)
        end
        if tick==1 or tick%25==0 then
            local f=io.open(root.."\\cache\\opened.lua","r")
            local text=f and f:read("*a") or nil
            if f then f:close() end
            if text~=state_text then
                local fn=text and load(text,"opened","t",{})
                local ok,data=pcall(function() return fn and fn() end)
                ready=ok and type(data)=="table" and data.ready and type(data.opened)=="table"
                opened=ready and data.opened or {}
                state_text=text state_revision=state_revision+1
            end
        end
        if not valid(engine) then engine=FindFirstOf("Engine") end
        local ok,pawn=pcall(function() return engine.GameViewport.GameInstance.LocalPlayers[1].PlayerController.Pawn end)
        if not enabled or not ready or not ok or not valid(pawn) then
            if last_enabled then for _,entry in pairs(layers) do pcall(hide,entry) end end
            last_enabled=false return
        end
        last_enabled=true
        local pawn_name=name(pawn)
        if pawn_name~=last_pawn then R.clear() last_pawn=pawn_name end
        -- Quest data never blocks the treasure radar: a failure here only switches quest markers off.
        if quest_failures<3 then
            local ok,err=true,nil
            if not quest_poll then
                if tick>=quest_retry then
                    local loaded
                    ok,loaded=pcall(load_quests)
                    if not ok then err=loaded elseif not loaded then quest_retry=tick+100 end
                end
            else
                ok,err=pcall(poll_quests,pawn)
            end
            if not ok then
                quest_failures=quest_failures+1
                quest_retry=tick+200
                log("Quests: "..tostring(err))
                if quest_failures>=3 then
                    for _,m in ipairs(quest_markers) do m.active=false end
                    quest_revision=quest_revision+1
                    log("Quest markers disabled after repeated errors")
                end
            end
        end
        -- Construction notifications replace steady global UObject scans.
        if events.dirty or tick==1 or tick%1500==0 then
            events.dirty=false
            local changed=false
            for _,obj in ipairs(FindAllOf("DWorldMapData") or {}) do
                if valid(obj) then
                    local i=obj.WorldMapDataInfo local id=tonumber(i.MapID)
                    local m={size=tonumber(i.WorldMapUISize),mini=tonumber(i.MiniMapUISize),dimension=tonumber(i.MapDimensions),cx=tonumber(i.MapDimensionsCenterX),cy=tonumber(i.MapDimensionsCenterY)}
                    if id and id>0 and m.dimension and m.dimension>0 and m.size>0 and m.mini>0 then
                        local old=maps[id]
                        if not old or old.dimension~=m.dimension or old.size~=m.size or old.mini~=m.mini or old.cx~=m.cx or old.cy~=m.cy then maps[id]=m changed=true end
                    end
                end
            end
            if changed then save_maps() end
            for _,layer in ipairs(FindAllOf("DLayerMap") or {}) do
                local n=name(layer)
                if n:find("/Engine/Transient",1,true) and not layers[n] then
                    layers[n]={layer=layer,markers={},qmarkers={},mini=n:find("DLayerMiniMap",1,true)~=nil}
                end
            end
        end
        if not valid(layout) then layout=StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
        local viewport=layout:GetViewportSize(pawn)
        local dpi=layout:GetViewportScale(pawn)
        local width,height=viewport.X/dpi,viewport.Y/dpi
        local pos=pawn:K2_GetActorLocation()
        for key,entry in pairs(layers) do
            local layer=entry.layer
            if not valid(layer) then layers[key]=nil
            elseif not layer:IsVisible() then if entry.active then hide(entry) end
            else
                local id=entry.mini and map_id(pawn_name) or map_id(name(layer.Map_0_0.Brush.ResourceObject))
                local data=id and maps[id]
                if not data then if entry.active then hide(entry) end
                else
                    local scale=layer.MapOverlay.RenderTransform.Scale.X
                    local origin=layer.MapOverlaySlot:GetPosition()
                    local content=layer.MapOverlayOutSideSlot:GetSize()
                    local stamp=table.concat({id,state_revision,quest_revision,origin.X,origin.Y,content.X,content.Y,scale,width,height,math.floor(pos.X/10),math.floor(pos.Y/10),math.floor(pos.Z/25)},":")
                    if stamp~=entry.stamp then
                        local parent=entry.canvas
                        if not valid(parent) then
                            if not valid(canvas_class) then canvas_class=StaticFindObject("/Script/UMG.CanvasPanel") end
                            parent=StaticConstructObject(canvas_class,layer.MapOverlayOutSide:GetParent())
                            assert(valid(parent),"Could not create marker canvas")
                            parent:SetVisibility(3)
                            local slot=layer.MapOverlayOutSide:GetParent():AddChild(parent)
                            slot:SetAutoSize(false)
                            slot:SetAnchors({Minimum={X=0,Y=0},Maximum={X=0,Y=0}})
                            slot:SetAlignment({X=0,Y=0})
                            slot:SetPosition({X=0,Y=0})
                            slot:SetZOrder(100)
                            entry.canvas=parent entry.canvas_slot=slot
                        end
                        if entry.width~=width or entry.height~=height then
                            entry.canvas_slot:SetSize({X=width,Y=height})
                            entry.width=width entry.height=height
                        end
                        local ratio=(entry.mini and data.mini or data.size)/data.dimension
                        local factor=ratio*scale
                        local offsetX=origin.X+content.X*0.5*scale-data.cx*factor
                        local offsetY=origin.Y+content.Y*0.5*scale-data.cy*factor
                        if entry.offsetX~=offsetX or entry.offsetY~=offsetY then
                            parent:SetRenderTranslation({X=offsetX,Y=offsetY})
                            entry.offsetX=offsetX entry.offsetY=offsetY
                        end
                        local visible,nearest,nearestD={},nil,math.huge
                        for _,p in ipairs(by_map[id] or {}) do
                            if not opened[p.save_id] then
                                local x,y=offsetX+p.x*factor,offsetY+p.y*factor
                                local dx,dy=p.x-pos.X,p.y-pos.Y local d=dx*dx+dy*dy
                                if (entry.mini and d*factor*factor<160*160) or (not entry.mini and x>=-12 and y>=-12 and x<=width+12 and y<=height+12) then
                                    local v={p=p,x=p.x*factor,y=p.y*factor} visible[#visible+1]=v
                                    if d<nearestD then nearest=v nearestD=d end
                                end
                            end
                        end
                        entry.active=true
                        local used,created,complete=0,0,true
                        for _,v in ipairs(visible) do
                            used=used+1
                            local item=entry.markers[used]
                            if not item or not valid(item.widget) then
                                if created>=32 then used=used-1 complete=false break end
                                item=make_marker(parent) entry.markers[used]=item created=created+1
                            end
                            local near=v==nearest
                            place(item,v.x,v.y,v.p.color..(near and "-near" or ""),near and 22 or 16,0,pawn)
                        end
                        for i=used+1,#entry.markers do
                            local item=entry.markers[i]
                            if item.visible and valid(item.widget) then item.widget:SetVisibility(2) item.visible=false end
                        end
                        local dz=nearest and nearest.p.z and nearest.p.z-(pos.Z-100) or 0
                        if nearest and math.abs(dz)>100 then
                            if not entry.arrow or not valid(entry.arrow.widget) then entry.arrow=make_marker(parent) end
                            place(entry.arrow,nearest.x-22,nearest.y,nearest.p.color.."-arrow",40,dz>0 and -90 or 90,pawn)
                        elseif entry.arrow and entry.arrow.visible then entry.arrow.widget:SetVisibility(2) entry.arrow.visible=false end
                        -- Quest markers, drawn above the treasure markers.
                        local qused=0
                        if quests_enabled then
                            for _,q in ipairs(quest_by_map[id] or {}) do
                                if q.active then
                                    local x,y=offsetX+q.x*factor,offsetY+q.y*factor
                                    local dx,dy=q.x-pos.X,q.y-pos.Y
                                    if (entry.mini and (dx*dx+dy*dy)*factor*factor<160*160) or (not entry.mini and x>=-12 and y>=-12 and x<=width+12 and y<=height+12) then
                                        qused=qused+1
                                        local item=entry.qmarkers[qused]
                                        if not item or not valid(item.widget) then
                                            if created>=32 then qused=qused-1 complete=false break end
                                            item=make_marker(parent,q.kind=="quest" and 102 or 101) entry.qmarkers[qused]=item created=created+1
                                        end
                                        place(item,q.x*factor,q.y*factor,q.kind,q.kind=="quest" and 26 or 22,0,pawn)
                                    end
                                end
                            end
                        end
                        for i=qused+1,#entry.qmarkers do
                            local item=entry.qmarkers[i]
                            if item.visible and valid(item.widget) then item.widget:SetVisibility(2) item.visible=false end
                        end
                        entry.stamp=complete and stamp or nil
                        if (used~=entry.last_count or qused~=entry.last_qcount) and (not entry.last_log or tick-entry.last_log>=100) then entry.last_log=tick log((entry.mini and "Minimap" or "World map").." visible="..used.." pooled="..#entry.markers.." new="..created.." quests="..qused) entry.last_count=used entry.last_qcount=qused end
                    end
                end
            end
        end
        last_error=nil
    end
    return R
end
