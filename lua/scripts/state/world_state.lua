-- world_state.lua
-- Phase 1: Rich spatial context + "Theory of You" interlocutor description.
--
-- scan(unit)  → { room_description, interlocutor_description }
--
-- room_description: a plain-English sentence describing the 5x5 tile area
--   around the unit, including tile type, furniture quality, and contaminants.
-- interlocutor_description: who the player character is, derived from fortress
--   entity data and active units list (adventure mode fallback).
--
-- All accesses use nil-guards or pcall.

local M = {}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function safe_get(tbl, ...)
    local cur = tbl
    for _, k in ipairs({...}) do
        if type(cur) ~= 'table' and type(cur) ~= 'userdata' then return nil end
        local ok, val = pcall(function() return cur[k] end)
        if not ok then return nil end
        cur = val
        if cur == nil then return nil end
    end
    return cur
end

-- ---------------------------------------------------------------------------
-- Tile type helpers
-- ---------------------------------------------------------------------------

-- Map tiletype shape names to simple room words
local _SHAPE_WORDS = {
    FLOOR         = 'floor',
    RAMP          = 'ramp',
    STAIR_UP      = 'staircase',
    STAIR_DOWN    = 'staircase',
    STAIR_UPDOWN  = 'staircase',
    WALL          = 'wall',
    OPEN_SPACE    = 'open air',
    BROOK_BED     = 'brook',
    BROOK_TOP     = 'brook',
    RIVER_BED     = 'riverbed',
}

local function tileshape_word(tt)
    if not tt then return nil end
    local ok, attrs = pcall(function() return df.tiletype.attrs[tt] end)
    if not ok or not attrs then return nil end
    local ok2, shape = pcall(function() return tostring(attrs.shape) end)
    if not ok2 or not shape then return nil end
    return _SHAPE_WORDS[shape] or shape:lower()
end

-- ---------------------------------------------------------------------------
-- Furniture / building quality
-- ---------------------------------------------------------------------------

-- Returns a word like "fine", "masterwork" etc. for the highest-quality
-- building/item occupying a given tile, or nil if none.
local function best_furniture_quality(x, y, z)
    -- Look at buildings at this exact tile
    local ok, bld = pcall(function()
        return dfhack.buildings.findAtTile(x, y, z)
    end)
    if not ok or not bld then return nil end

    local ok_q, q = pcall(function() return bld.quality end)
    if not ok_q or not q then return nil end

    -- df.item_quality: 0=ordinary,1=well-crafted,2=finely,3=superior,4=exceptional,5=masterwork
    local qwords = { [1]='well-crafted', [2]='fine', [3]='superior',
                     [4]='exceptional',  [5]='masterwork' }
    return qwords[q] or nil
end

-- ---------------------------------------------------------------------------
-- Contaminant scan (block-level spatter events)
-- ---------------------------------------------------------------------------

-- Returns a set of flags: { blood=bool, vomit=bool, miasma=bool }
-- We scan the block that contains (x,y,z) for spatter events.
local function scan_contaminants_in_block(bx, by, z)
    local contam = { blood = false, vomit = false, miasma = false }
    local ok, block = pcall(function()
        return dfhack.maps.getTileBlock(bx * 16, by * 16, z)
    end)
    if not ok or not block then return contam end

    local ok_ev, events = pcall(function() return block.block_events end)
    if not ok_ev or not events then return contam end

    for _, ev in ipairs(events) do
        local ok_t, evtype_str = pcall(function()
            return tostring(df.block_square_event_type[ev:getType()])
        end)
        if not ok_t then goto next_ev end

        if evtype_str == 'material_spatter' then
            -- Blood and vomit are creature materials (mat_type >= 19 in DF's
            -- material system).  Inorganic materials are mat_type 0; plant
            -- materials are 1..18; creature materials start at 19.
            -- Rather than resolve the exact creature material token (which
            -- requires a creature_raw lookup keyed on race + caste), we use
            -- mat_type to discriminate: any creature-derived spatter is
            -- treated as blood, except we additionally check mat_state for
            -- a rough vomit heuristic (vomit has mat_state Paste or Powder
            -- while fresh blood is Liquid).
            local ok_m, mat_type  = pcall(function() return ev.mat_type end)
            local ok_s, mat_state = pcall(function()
                return tostring(df.matter_state[ev.mat_state])
            end)

            if ok_m and mat_type then
                if mat_type >= 19 then
                    -- Creature-derived spatter
                    if ok_s and (mat_state == 'Paste' or mat_state == 'Powder') then
                        contam.vomit = true
                    else
                        contam.blood = true
                    end
                elseif mat_type == 0 then
                    -- Inorganic spatter (could be mud, slag, etc.) — skip,
                    -- not relevant to the room description.
                end
            end

        elseif evtype_str == 'flow_record' then
            -- Miasma is a gas flow recorded per-block
            local ok_f, ftype = pcall(function()
                return tostring(df.flow_type[ev.flow_type])
            end)
            if ok_f and ftype == 'Miasma' then contam.miasma = true end
        end

        ::next_ev::
    end
    return contam
end

-- ---------------------------------------------------------------------------
-- Nearby units classifier
-- ---------------------------------------------------------------------------

local function classify_nearby_units(cx, cy, cz, radius)
    local dwarves  = 0
    local animals  = 0
    local visitors = 0

    local ok, active = pcall(function() return df.global.world.units.active end)
    if not ok or not active then
        return dwarves, animals, visitors
    end

    local r2 = radius * radius
    for _, u in ipairs(active) do
        -- Skip the unit itself (checked externally) and dead units
        local ok_dead, dead = pcall(function() return u.flags1.dead end)
        if ok_dead and not dead then
            local ok_pos, pos = pcall(function() return u.pos end)
            if ok_pos and pos then
                local dx = pos.x - cx
                local dy = pos.y - cy
                local dz = pos.z - cz
                if dz == 0 and (dx*dx + dy*dy) <= r2 then
                    -- Classify: check civ / tame flags
                    local ok_civ, civ = pcall(function() return u.civ_id end)
                    local ok_tame, tame = pcall(function() return u.flags1.tame end)
                    local ok_race, race_id = pcall(function() return u.race end)

                    -- Check if this is the player-controlled dwarf via unit type
                    local ok_control, controlled = pcall(function()
                        return u.flags1.marauder -- adventurer flag
                    end)

                    if ok_tame and tame then
                        animals = animals + 1
                    elseif ok_civ and civ and civ >= 0 then
                        -- Has a civ — dwarf or visitor
                        local ok_vis, vis = pcall(function()
                            return u.flags1.diplomat or u.flags2.visitor
                        end)
                        if ok_vis and vis then
                            visitors = visitors + 1
                        else
                            dwarves = dwarves + 1
                        end
                    else
                        animals = animals + 1
                    end
                end
            end
        end
    end
    return dwarves, animals, visitors
end

-- ---------------------------------------------------------------------------
-- Room label heuristic
-- ---------------------------------------------------------------------------
-- We approximate room type from the buildings present in the scan area.

local _BUILDING_ROOM_HINTS = {
    -- building type string fragment → room label
    { 'TABLE',      'dining hall'   },
    { 'CHAIR',      'dining hall'   },
    { 'BED',        'bedroom'       },
    { 'COFFIN',     'burial chamber'},
    { 'WEAPONRACK', 'barracks'      },
    { 'ARMORSTAND', 'barracks'      },
    { 'ANVIL',      'forge'         },
    { 'FURNACE',    'smelter'       },
    { 'STILL',      'brewery'       },
    { 'TRACTION',   'hospital'      },
    { 'DOOR',       nil             },  -- skip
    { 'TRADEDEPOT', 'trade depot'   },
    { 'STATUE',     'meeting hall'  },
    { 'CABINET',    'storage room'  },
    { 'CHEST',      'storage room'  },
    { 'CAGE',       'prison'        },
    { 'THRONE',     "lord's hall"   },
    { 'FARM_PLOT',  'farm'          },
}

local function guess_room_label(cx, cy, cz, radius)
    local counts = {}  -- label → count

    for dy = -radius, radius do
        for dx = -radius, radius do
            local x = cx + dx
            local y = cy + dy
            local ok, bld = pcall(function()
                return dfhack.buildings.findAtTile(x, y, cz)
            end)
            if ok and bld then
                local ok_t, btype = pcall(function()
                    return tostring(df.building_type[bld:getType()]):upper()
                end)
                if ok_t then
                    for _, hint in ipairs(_BUILDING_ROOM_HINTS) do
                        if hint[2] and btype:find(hint[1]) then
                            counts[hint[2]] = (counts[hint[2]] or 0) + 1
                        end
                    end
                end
            end
        end
    end

    -- Return most frequent label
    local best_label, best_count = nil, 0
    for label, count in pairs(counts) do
        if count > best_count then
            best_label = label
            best_count = count
        end
    end
    return best_label
end

-- ---------------------------------------------------------------------------
-- Tile scan summary
-- ---------------------------------------------------------------------------

local function scan_tiles(cx, cy, cz, radius)
    local floor_count  = 0
    local natural      = false
    local has_blood    = false
    local has_vomit    = false
    local has_miasma   = false
    local best_quality = nil
    local checked_blocks = {}  -- avoid re-scanning same 16x16 block

    for dy = -radius, radius do
        for dx = -radius, radius do
            local x = cx + dx
            local y = cy + dy

            local ok_tt, tt = pcall(function()
                return dfhack.maps.getTileType(x, y, cz)
            end)
            if ok_tt and tt then
                local shape = tileshape_word(tt)
                if shape == 'floor' then floor_count = floor_count + 1 end

                -- Check if natural (unmined rock or soil)
                local ok_attr, attr = pcall(function()
                    return df.tiletype.attrs[tt]
                end)
                if ok_attr and attr then
                    local ok_mat, mat = pcall(function()
                        return tostring(attr.material)
                    end)
                    if ok_mat and (mat == 'STONE' or mat == 'SOIL') then
                        natural = true
                    end
                end
            end

            -- Furniture quality
            local q = best_furniture_quality(x, y, cz)
            if q then
                -- Pick highest tier seen
                local tiers = { ordinary=0, ['well-crafted']=1, fine=2, superior=3,
                                 exceptional=4, masterwork=5 }
                local cur_t  = tiers[best_quality] or -1
                local new_t  = tiers[q] or 0
                if new_t > cur_t then best_quality = q end
            end

            -- Contaminants: one scan per block
            local bx = math.floor(x / 16)
            local by = math.floor(y / 16)
            local bkey = bx .. ',' .. by
            if not checked_blocks[bkey] then
                checked_blocks[bkey] = true
                local c = scan_contaminants_in_block(bx, by, cz)
                if c.blood  then has_blood  = true end
                if c.vomit  then has_vomit  = true end
                if c.miasma then has_miasma = true end
            end
        end
    end

    return {
        floor_count  = floor_count,
        natural      = natural,
        has_blood    = has_blood,
        has_vomit    = has_vomit,
        has_miasma   = has_miasma,
        best_quality = best_quality,
    }
end

-- ---------------------------------------------------------------------------
-- Room description builder
-- ---------------------------------------------------------------------------

local function build_room_description(unit)
    local ok_pos, pos = pcall(function() return unit.pos end)
    if not ok_pos or not pos then return '' end

    local cx, cy, cz = pos.x, pos.y, pos.z
    local RADIUS = 2  -- 5x5 = radius 2 from center

    local tiles   = scan_tiles(cx, cy, cz, RADIUS)
    local dwarves, animals, visitors = classify_nearby_units(cx, cy, cz, RADIUS + 1)
    local room_label = guess_room_label(cx, cy, cz, RADIUS)

    -- Assemble the sentence
    local parts = {}

    -- Location
    if room_label then
        if dwarves > 4 then
            table.insert(parts, 'You are in a crowded ' .. room_label .. '.')
        elseif dwarves > 1 then
            table.insert(parts, 'You are in a busy ' .. room_label .. '.')
        else
            table.insert(parts, 'You are in a ' .. room_label .. '.')
        end
    elseif tiles.natural then
        table.insert(parts, 'You are in a rough-hewn stone tunnel.')
    else
        table.insert(parts, 'You are in an open area of the fortress.')
    end

    -- Quality
    if tiles.best_quality == 'masterwork' then
        table.insert(parts, 'The craftsmanship here is masterwork — nearly perfect.')
    elseif tiles.best_quality == 'exceptional' then
        table.insert(parts, 'The furnishings are of exceptional quality.')
    elseif tiles.best_quality == 'fine' or tiles.best_quality == 'superior' then
        table.insert(parts, 'The furnishings are well-made.')
    end

    -- Nearby beings
    if animals > 0 then
        table.insert(parts, 'There are tame animals nearby.')
    end
    if visitors > 0 then
        table.insert(parts, (visitors == 1 and 'A visitor' or 'Several visitors')
            .. ' linger in the area.')
    end

    -- Contaminants (most alarming first)
    if tiles.has_miasma then
        table.insert(parts, 'The air reeks of rotting miasma.')
    end
    if tiles.has_blood then
        table.insert(parts, 'There is blood on the floor.')
    end
    if tiles.has_vomit then
        table.insert(parts, 'There is vomit on the floor.')
    end

    return table.concat(parts, ' ')
end

-- ---------------------------------------------------------------------------
-- Theory of You — interlocutor description
-- ---------------------------------------------------------------------------

local function build_interlocutor_description()
    -- Try fortress mode: get fortress entity name + race
    local entity_name = nil
    local entity_race = nil
    local legend_count = 0

    local ok_plot, plotinfo = pcall(function() return df.global.plotinfo end)
    if ok_plot and plotinfo then
        local ok_ent, ent_id = pcall(function()
            return plotinfo.main.fortress_entity
        end)
        if ok_ent and ent_id and ent_id >= 0 then
            local ok_e, ent = pcall(function()
                return df.historical_entity.find(ent_id)
            end)
            if ok_e and ent then
                local ok_n, ename = pcall(function()
                    return dfhack.TranslateName(ent.name, true)
                end)
                if ok_n and ename and ename ~= '' then
                    entity_name = ename
                end

                -- Count heroes/legends in the entity
                local ok_hf, figures = pcall(function() return ent.histfig_ids end)
                if ok_hf and figures then
                    for _, hf_id in ipairs(figures) do
                        local ok_hfig, hfig = pcall(function()
                            return df.historical_figure.find(hf_id)
                        end)
                        if ok_hfig and hfig then
                            local ok_flag, notable = pcall(function()
                                return hfig.flags.APPEARED_IN_DREAMS or
                                       hfig.flags.LOCAL_HERO
                            end)
                            if ok_flag and notable then
                                legend_count = legend_count + 1
                            end
                        end
                    end
                end
            end
        end
    end

    -- Try to identify the active player unit (adventure mode or fortress overseer)
    local player_name = nil
    local player_race = nil

    local ok_units, active = pcall(function() return df.global.world.units.active end)
    if ok_units and active then
        -- In adventure mode, [0] is the player; in fortress mode look for marauder/player flag
        for i = 0, math.min(10, #active - 1) do
            local u = active[i]
            if u then
                local ok_p, is_player = pcall(function()
                    return u.flags1.marauder or u.flags1.active_diplomat
                end)
                if ok_p and is_player then
                    local ok_n, pname = pcall(function()
                        return dfhack.TranslateName(u.name, true)
                    end)
                    if ok_n and pname and pname ~= '' then
                        player_name = pname
                    end
                    local ok_r, race_raw = pcall(function()
                        return df.creature_raw.find(u.race)
                    end)
                    if ok_r and race_raw then
                        local ok_rn, rn = pcall(function() return race_raw.name[0] end)
                        if ok_rn and rn then
                            player_race = rn:gsub("^%l", string.upper)
                        end
                    end
                    break
                end
            end
        end
    end

    -- Build the line
    local parts = {}
    if player_name and player_race then
        table.insert(parts, string.format('You are speaking to %s, a %s.',
            player_name, player_race))
    elseif player_name then
        table.insert(parts, 'You are speaking to ' .. player_name .. '.')
    elseif player_race then
        table.insert(parts, 'You are speaking to a ' .. player_race .. '.')
    else
        table.insert(parts, 'You are speaking to the fortress overseer.')
    end

    if entity_name then
        table.insert(parts, string.format('They represent the civilization of %s.', entity_name))
    end

    if legend_count > 0 then
        table.insert(parts, string.format(
            'Their civilization has produced %d known hero%s.',
            legend_count, legend_count == 1 and '' or 'es'))
    end

    return table.concat(parts, ' ')
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Scan the spatial context around a unit and build plain-English descriptions.
--- @param unit df.unit
--- @return table { room_description: string, interlocutor_description: string }
function M.scan(unit)
    local room_desc = ''
    local inter_desc = ''

    if unit then
        local ok_r, r = pcall(build_room_description, unit)
        if ok_r then room_desc = r or '' end

        local ok_i, i = pcall(build_interlocutor_description)
        if ok_i then inter_desc = i or '' end
    end

    return {
        room_description         = room_desc,
        interlocutor_description = inter_desc,
    }
end

return M
