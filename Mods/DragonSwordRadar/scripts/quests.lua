-- Quest givers, read from the game's own quest tables.
--   "quest": side quests the game reports as acceptable that start by talking to an NPC
--   "talk":  random NPC quests (the "..." NPCs) that have not been finished
return function(log)
    local Q = {revision = 0}

    local ACCEPT_NPC, ACCEPT_INTERACT_NPC = 2, 7            -- EQuestAcceptType
    local NONE, ACCEPTABLE, FINISHED, FAILED = 0, 1, 3, 4   -- DENM_QuestState
    local COND_QUEST_CLEAR = 3                              -- EConditionType

    local entries, by_map, markers = nil, {}, {}
    local util, cursor, story_state, signature = nil, 0, {}, nil
    local failures, retry_at, ticks = 0, 0, 0

    local function valid(o)
        local ok, v = pcall(function() return o ~= nil and o:IsValid() end)
        return ok and v
    end

    local function load()
        local main_tbl = FindFirstOf("DQuestDataTable")
        local random_tbl = FindFirstOf("DDynamicQuestDataTable")
        local pos_tbl = FindFirstOf("DActorPositionTable")
        if not (valid(main_tbl) and valid(random_tbl) and valid(pos_tbl)) then return false end

        local list, side, random, prereq, wanted = {}, {}, {}, {}, {}
        main_tbl.QuestMainDataMap.Data:ForEach(function(k, v)
            local accept = v:get().AcceptType
            if accept == ACCEPT_NPC or accept == ACCEPT_INTERACT_NPC then
                local e = {id = k:get(), random = false, kind = "quest"}
                list[#list + 1] = e side[e.id] = e
            end
        end)
        -- A side quest starts with a conversation; its first step names where that NPC stands.
        main_tbl.QuestStepDataMap.Data:ForEach(function(k, v)
            local e = side[k:get()]
            if not e then return end
            local first
            v:get().QuestStepDataArray:ForEach(function(_, el)
                local s = el:get()
                if not first or s.StepID < first then
                    first = s.StepID
                    e.spot_name = s.StepPosition:ToString()
                    e.group = s.IconMapGroupID
                end
            end)
            if e.spot_name and e.spot_name ~= "" then wanted[e.spot_name] = true end
        end)
        random_tbl.DynamicQuestMainMap.Data:ForEach(function(_, v)
            v:get().DynamicQuestMainDataMap:ForEach(function(k2, v2)
                local q = v2:get()
                local e = {id = k2:get(), random = true, kind = "talk"}
                if q.AcceptConditionType == COND_QUEST_CLEAR then
                    e.requires = q.AcceptConditionValue1
                    prereq[e.requires] = true
                end
                list[#list + 1] = e random[e.id] = e
            end)
        end)

        -- Named positions -> coordinates. Groups 100, 200, ... are the open-world maps.
        local named = {}
        pos_tbl.DataMap.Data:ForEach(function(k, v)
            local group = k:get()
            if group % 100 ~= 0 or group >= 10000 then return end
            v:get().Data:ForEach(function(_, v2)
                local d = v2:get()
                local name = d.Name:ToString()
                if wanted[name] then
                    named[name] = named[name] or {}
                    named[name][group] = {x = d.PosX, y = d.PosY, z = d.PosZ}
                    return
                end
                -- Random quests use DQ<id>_<step>_<what>; keep the earliest real spot
                -- (cameras, lights and trigger volumes rank after it).
                local id, rest = name:match("^DQ(%d+)_(.+)$")
                local e = id and random[tonumber(id)]
                if not e then return end
                local helper = (rest:find("Move_Check", 1, true) or rest:find("Camera", 1, true)
                    or rest:find("Light", 1, true) or rest:find("Empty", 1, true)) and 1 or 0
                local rank = (tonumber(rest:match("^(%d+)_")) or 0) * 2 + helper
                if not e.rank or rank < e.rank or (rank == e.rank and name < e.spot_name) then
                    e.rank, e.spot_name = rank, name
                    e.spot = {group = group, x = d.PosX, y = d.PosY, z = d.PosZ}
                end
            end)
        end)

        local seen, maps, all, counts = {}, {}, {}, {quest = 0, talk = 0}
        local function attach(e, group, p)
            local key = e.kind .. ":" .. group .. ":" .. p.x .. ":" .. p.y
            local m = seen[key]
            if not m then
                m = {x = p.x, y = p.y, z = p.z, kind = e.kind, active = false}
                seen[key] = m all[#all + 1] = m
                maps[group] = maps[group] or {}
                table.insert(maps[group], m)
            end
            e.marker = m
            counts[e.kind] = counts[e.kind] + 1
        end
        local poll = {}
        for _, e in ipairs(list) do
            if e.random then
                if e.spot then attach(e, e.spot.group, e.spot) end
            else
                local spots = e.spot_name and named[e.spot_name]
                if spots then
                    local group = spots[e.group] and e.group or next(spots)
                    attach(e, group, spots[group])
                end
            end
            if e.marker then poll[#poll + 1] = e end
        end
        for id in pairs(prereq) do poll[#poll + 1] = {id = id, random = false} end
        entries, by_map, markers = poll, maps, all
        cursor, signature, story_state = 0, nil, {}
        log("Quest catalog: " .. counts.quest .. " NPC quests, " .. counts.talk .. " random quests, " .. #all .. " places")
        return true
    end

    -- Checks a few quests per call; markers change after each full pass.
    local function poll(context, finished)
        if not valid(util) then util = StaticFindObject("/Script/DS.Default__DETUtil") end
        local n = #entries
        for _ = 1, math.min(8, n) do
            cursor = cursor + 1
            local e = entries[cursor]
            local step, current, max, state = {}, {}, {}, {}
            util:GetQuestInfoInStandAlone(context, e.id, e.random, step, current, max, state)
            e.state = state.QuestState
            if not e.random then story_state[e.id] = e.state end
            if cursor >= n then
                cursor = 0
                local ids = {}
                for _, m in ipairs(markers) do m.want = false end
                for _, q in ipairs(entries) do
                    if q.marker then
                        local show
                        if q.random then
                            -- The live state forgets finished random quests after a restart; the save does not.
                            show = finished ~= nil and (q.state == NONE or q.state == FAILED) and not finished[q.id]
                                and (not q.requires or story_state[q.requires] == FINISHED)
                        else
                            show = q.state == ACCEPTABLE
                        end
                        if show then q.marker.want = true ids[#ids + 1] = q.id end
                    end
                end
                local sig = table.concat(ids, ",")
                if sig ~= signature then
                    signature = sig
                    local shown = {quest = 0, talk = 0}
                    for _, m in ipairs(markers) do
                        m.active = m.want
                        if m.active then shown[m.kind] = shown[m.kind] + 1 end
                    end
                    Q.revision = Q.revision + 1
                    log("Quest markers: " .. shown.quest .. " NPC quests, " .. shown.talk .. " random quests")
                end
                return
            end
        end
    end

    -- Never lets a problem here stop the rest of the radar.
    function Q.update(context, finished)
        ticks = ticks + 1
        if failures >= 3 or ticks < retry_at then return end
        local ok, err
        if not entries then
            ok, err = pcall(load)
            if ok and not err then retry_at = ticks + 100 end
        else
            ok, err = pcall(poll, context, finished)
        end
        if not ok then
            failures = failures + 1
            retry_at = ticks + 200
            log("Quests: " .. tostring(err))
            if failures >= 3 then
                for _, m in ipairs(markers) do m.active = false end
                Q.revision = Q.revision + 1
                log("Quest markers turned off after repeated errors")
            end
        end
    end

    function Q.on_map(map_id) return by_map[map_id] or {} end

    return Q
end
