-- screen_overlay.lua
-- Phase 6: Seamless UI Overlays
--
-- Hooks into two DF screens:
--   1. Unit view (dfhack.gui.getCurFocus() contains "unitview") — fires a
--      context request for the viewed unit and renders the LLM reply as an
--      overlay panel.
--   2. Engraving inspect — generates dynamic flavour text on first view and
--      caches it per engraving tile.
--
-- IPC base: /home/nemoclaw/dwarf-ai/lua/ipc/

local json     = require('json')
local gui      = require('gui')
local widgets  = require('gui.widgets')
local guidm    = require('gui.dwarfmode')

local IPC_CONTEXT_DIR   = '/home/nemoclaw/dwarf-ai/lua/ipc/context'
local IPC_RESPONSES_DIR = '/home/nemoclaw/dwarf-ai/lua/ipc/responses'
local POLL_TICKS        = 20   -- poll frequency for overlay
local OVERLAY_TIMEOUT   = 8.0  -- wall-clock seconds before showing fallback

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function uuid()
    math.randomseed(dfhack.getTickCount() + math.random(99999))
    return string.format('ovl-%d-%d', dfhack.getTickCount(), math.random(10000, 99999))
end

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

local function atomic_write(path, text)
    local tmp = path .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return false end
    f:write(text)
    f:close()
    os.rename(tmp, path)
    return true
end

local function read_json(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local raw = f:read('*all')
    f:close()
    if not raw or raw == '' then return nil end
    local ok, data = pcall(function() return json.decode(raw) end)
    return ok and data or nil
end

local function ensure_dir(path)
    if dfhack.filesystem and dfhack.filesystem.mkdir_recursive then
        pcall(function() dfhack.filesystem.mkdir_recursive(path) end)
    end
end

-- ─── NPC state extraction (minimal — full version in context_writer.lua) ─────

local function get_unit_name(unit)
    if not unit then return 'Unknown' end
    local ok1, hf = pcall(function()
        return df.historical_figure.find(unit.hist_figure_id)
    end)
    if ok1 and hf then
        local ok2, n = pcall(function() return dfhack.TranslateName(hf.name, true) end)
        if ok2 and n and n ~= '' then return n end
    end
    local ok3, n2 = pcall(function() return dfhack.TranslateName(unit.name, true) end)
    if ok3 and n2 and n2 ~= '' then return n2 end
    return 'Unknown'
end

local function extract_unit_state(unit)
    if not unit then return nil end
    local state = {
        unit_id      = tonumber(unit.id) or 0,
        npc_name     = get_unit_name(unit),
        npc_race     = '',
        npc_profession = '',
        facets       = {},
        values       = {},
        emotions     = {},
        wounds       = {},
        hunger  = 0, thirst = 0, fatigue = 0, alcohol = 0,
        room_description = '',
        interlocutor_description = '',
        core_memories = {},
    }

    -- Race
    local ok_r, race_raw = pcall(function() return df.creature_raw.find(unit.race) end)
    if ok_r and race_raw then
        local ok_rn, rn = pcall(function() return race_raw.name[0] end)
        if ok_rn and rn then
            state.npc_race = rn:gsub("^%l", string.upper)
        end
    end

    -- Profession
    local ok_p, prof = pcall(function()
        return df['profession'][unit.profession] or 'UNKNOWN'
    end)
    if ok_p then
        state.npc_profession = tostring(prof):lower():gsub('_', ' ')
    end

    -- Facets / values / emotions from soul
    local soul = safe_get(unit, 'status', 'current_soul')
    if soul then
        local facets = safe_get(soul, 'personality', 'facets')
        if facets then
            local ft = df.personality_facet_type
            for k, v in pairs(ft) do
                if type(k) == 'string' then
                    local ok_f, val = pcall(function() return facets[v] end)
                    if ok_f and type(val) == 'number' then
                        state.facets[k] = val
                    end
                end
            end
        end

        local values = safe_get(soul, 'personality', 'values')
        if values then
            local bt = df.belief_system_type
            for k, v in pairs(bt) do
                if type(k) == 'string' then
                    local ok_v, val = pcall(function() return values[v] end)
                    if ok_v and type(val) == 'number' then
                        state.values[k] = val
                    end
                end
            end
        end

        local emotions = safe_get(soul, 'emotions')
        if emotions then
            local elist = {}
            for _, em in ipairs(emotions) do
                local ok_e, etype   = pcall(function() return df['emotion_type'][em.type] end)
                local ok_s, strength = pcall(function() return em.strength end)
                local ok_t, thought  = pcall(function() return em.thought end)
                if ok_e and ok_s then
                    table.insert(elist, {
                        type     = tostring(etype or 'unknown'):lower(),
                        strength = strength or 0,
                        thought  = ok_t and tostring(thought or '') or '',
                    })
                end
            end
            table.sort(elist, function(a, b) return a.strength > b.strength end)
            for i = 1, math.min(3, #elist) do
                table.insert(state.emotions, elist[i])
            end
        end
    end

    -- Counters
    local function sc(key)
        local ok, v = pcall(function() return unit.counters[key] end)
        return ok and (tonumber(v) or 0) or 0
    end
    state.hunger  = sc('hunger_timer')
    state.thirst  = sc('thirst_timer')
    state.fatigue = sc('fatigue_timer')
    state.alcohol = sc('alcohol')

    return state
end

-- ─── Engraving cache ──────────────────────────────────────────────────────────
-- Key: "x,y,z" → engraving text string
local _engraving_cache = {}

local function engraving_cache_key(pos)
    if not pos then return nil end
    return string.format('%d,%d,%d', pos.x or 0, pos.y or 0, pos.z or 0)
end

local function get_engraving_at(pos)
    if not pos then return nil end
    -- Walk world.engravings looking for matching position
    local ok, engravings = pcall(function() return df.global.world.engravings end)
    if not ok or not engravings then return nil end
    for _, eng in ipairs(engravings) do
        local ok_p, ep = pcall(function() return eng.pos end)
        if ok_p and ep and ep.x == pos.x and ep.y == pos.y and ep.z == pos.z then
            return eng
        end
    end
    return nil
end

local function build_engraving_context(eng, pos)
    -- Produce a minimal context dict for engraving flavour generation
    local subj = 'unknown subject'
    local ok_s, s = pcall(function() return eng.subject end)
    if ok_s and s then subj = tostring(s) end

    local artist = 'an unknown artisan'
    local ok_a, a = pcall(function()
        local hf = df.historical_figure.find(eng.artisan_hfid)
        if hf then return dfhack.TranslateName(hf.name, true) end
        return nil
    end)
    if ok_a and a then artist = a end

    return {
        interaction_id = uuid(),
        type           = 'engraving_view',
        unit_id        = 0,
        player_input   = 'Describe this engraving for the player.',
        npc_name       = artist,
        npc_race       = 'Dwarf',
        npc_profession = 'engraver',
        facets         = {}, values = {}, emotions = {}, wounds = {},
        hunger = 0, thirst = 0, fatigue = 0, alcohol = 0,
        room_description = string.format(
            'This is an engraving at (%d,%d,%d) depicting %s, carved by %s.',
            pos.x, pos.y, pos.z, subj, artist
        ),
        interlocutor_description = '',
        core_memories = {},
    }
end

-- ─── Overlay panel (DFHack gui.Screen subclass) ───────────────────────────────

local OverlayScreen = defclass(OverlayScreen, gui.Screen)
OverlayScreen.ATTRS {
    text     = DEFAULT_NIL,   -- string displayed in the panel
    title    = 'Unit',
    spinning = false,
    focus_path = 'dfai/overlay',
}

local SPINNER_FRAMES = { '/', '-', '\\', '|' }
local _spinner_idx   = 1

function OverlayScreen:init()
    self._tick = 0
end

function OverlayScreen:onRenderFrame(dc, rect)
    -- Render parent screen underneath
    self:renderParent()

    local text = self.text
    if self.spinning then
        _spinner_idx = (_spinner_idx % #SPINNER_FRAMES) + 1
        text = SPINNER_FRAMES[_spinner_idx] .. '  ' .. (text or '...')
    end

    -- Word-wrap text into lines of max 38 chars
    local lines = {}
    local max_w = 38
    local raw = text or ''
    for para in (raw .. '\n'):gmatch('([^\n]*)\n') do
        if #para == 0 then
            table.insert(lines, '')
        else
            local i = 1
            while i <= #para do
                local chunk = para:sub(i, i + max_w - 1)
                -- Back-off to last space if possible
                if #chunk == max_w and para:sub(i + max_w, i + max_w) ~= '' then
                    local sp = chunk:match('.*()%s')
                    if sp and sp > 1 then chunk = para:sub(i, i + sp - 2) end
                end
                table.insert(lines, chunk)
                i = i + #chunk + (#chunk < max_w and 0 or 0)
                -- Advance past leading space on next segment
                if para:sub(i, i) == ' ' then i = i + 1 end
            end
        end
    end

    -- Panel dimensions
    local panel_w = max_w + 4
    local panel_h = math.max(5, #lines + 4)
    local screen_w, screen_h = dfhack.screen.getWindowSize()
    local px = screen_w - panel_w - 2
    local py = 2

    -- Background fill
    dc:seek(px, py)
    for row = 0, panel_h - 1 do
        dc:seek(px, py + row)
        dc:string(string.rep(' ', panel_w), COLOR_BLACK)
    end

    -- Border
    dc:seek(px, py):string('+', COLOR_GREY)
    dc:string(string.rep('-', panel_w - 2), COLOR_GREY)
    dc:string('+', COLOR_GREY)
    for row = 1, panel_h - 2 do
        dc:seek(px, py + row):string('|', COLOR_GREY)
        dc:seek(px + panel_w - 1, py + row):string('|', COLOR_GREY)
    end
    dc:seek(px, py + panel_h - 1):string('+', COLOR_GREY)
    dc:string(string.rep('-', panel_w - 2), COLOR_GREY)
    dc:string('+', COLOR_GREY)

    -- Title
    local title_text = ' ' .. (self.title or 'Unit') .. ' '
    local title_x = px + math.floor((panel_w - #title_text) / 2)
    dc:seek(title_x, py):string(title_text, COLOR_WHITE)

    -- Content
    for i, line in ipairs(lines) do
        dc:seek(px + 2, py + 1 + i):string(line, COLOR_LIGHTGREY)
    end
end

function OverlayScreen:onInput(keys)
    if keys.LEAVESCREEN or keys.LEAVESCREEN_ALL or keys.SELECT or keys.SECONDSCROLL_UP then
        self:dismiss()
        return true
    end
    return self:passInputToParent(keys)
end

-- ─── State machine for active overlay requests ────────────────────────────────

local _active_overlays = {}
-- _active_overlays[interaction_id] = {
--   ts, unit_id, type, screen (OverlayScreen), cache_key
-- }

local function fire_unit_overlay(unit)
    if not unit then return end
    local state = extract_unit_state(unit)
    if not state then return end

    local iid = uuid()
    state.interaction_id = iid
    state.type           = 'unit_view'
    state.player_input   = 'Briefly describe how this unit appears right now. 1-3 sentences.'

    ensure_dir(IPC_CONTEXT_DIR)
    local path = IPC_CONTEXT_DIR .. '/' .. iid .. '.json'
    local ok_enc, encoded = pcall(function() return json.encode(state) end)
    if not ok_enc then return end
    if not atomic_write(path, encoded) then return end

    local overlay = OverlayScreen {
        title    = state.npc_name,
        text     = '...',
        spinning = true,
    }
    overlay:show()

    _active_overlays[iid] = {
        ts        = os.time and os.time() or 0,
        unit_id   = state.unit_id,
        type      = 'unit_view',
        screen    = overlay,
        cache_key = nil,
    }
end

local function fire_engraving_overlay(pos)
    if not pos then return end
    local ckey = engraving_cache_key(pos)
    if not ckey then return end

    -- Return cached text immediately if available
    if _engraving_cache[ckey] then
        local overlay = OverlayScreen {
            title    = 'Engraving',
            text     = _engraving_cache[ckey],
            spinning = false,
        }
        overlay:show()
        return
    end

    local eng = get_engraving_at(pos)
    if not eng then return end

    local ctx = build_engraving_context(eng, pos)
    local iid = ctx.interaction_id

    ensure_dir(IPC_CONTEXT_DIR)
    local path = IPC_CONTEXT_DIR .. '/' .. iid .. '.json'
    local ok_enc, encoded = pcall(function() return json.encode(ctx) end)
    if not ok_enc then return end
    if not atomic_write(path, encoded) then return end

    local overlay = OverlayScreen {
        title    = 'Engraving',
        text     = '...',
        spinning = true,
    }
    overlay:show()

    _active_overlays[iid] = {
        ts        = os.time and os.time() or 0,
        unit_id   = 0,
        type      = 'engraving_view',
        screen    = overlay,
        cache_key = ckey,
    }
end

-- ─── Poll loop — resolves pending overlays ────────────────────────────────────

local _poll_counter = 0

local function poll_overlays()
    _poll_counter = _poll_counter + 1
    if _poll_counter < POLL_TICKS then
        dfhack.timeout(1, 'ticks', poll_overlays)
        return
    end
    _poll_counter = 0

    local now = os.time and os.time() or 0

    for iid, info in pairs(_active_overlays) do
        -- Dismiss if parent screen closed
        if not info.screen or not info.screen:isActive() then
            _active_overlays[iid] = nil
        else
            -- Check timeout
            if (now - info.ts) >= OVERLAY_TIMEOUT then
                info.screen.text     = '*...no response...*'
                info.screen.spinning = false
                _active_overlays[iid] = nil
            else
                -- Check for response file
                local resp_path = IPC_RESPONSES_DIR .. '/' .. iid .. '.json'
                local data = read_json(resp_path)
                if data then
                    local text = data.dialogue or '...'
                    info.screen.text     = text
                    info.screen.spinning = false

                    -- Cache engraving results
                    if info.type == 'engraving_view' and info.cache_key then
                        _engraving_cache[info.cache_key] = text
                    end

                    os.remove(resp_path)
                    _active_overlays[iid] = nil
                end
            end
        end
    end

    dfhack.timeout(1, 'ticks', poll_overlays)
end

-- ─── Screen focus watcher — detect unit view and engraving inspect ────────────

local _last_focus  = ''
local _last_unit   = nil   -- last unit_id shown
local _last_engpos = nil   -- last engraving pos shown

local function get_cursor_unit()
    local cursor = guidm.getCursorPos and guidm.getCursorPos()
    if not cursor then return nil end
    for _, unit in ipairs(df.global.world.units.active) do
        local ok, pos = pcall(function() return unit.pos end)
        if ok and pos and pos.x == cursor.x and pos.y == cursor.y and pos.z == cursor.z then
            return unit
        end
    end
    return nil
end

local function focus_watcher()
    local ok_f, focus = pcall(function() return dfhack.gui.getCurFocus(true) end)
    if not ok_f or not focus then
        dfhack.timeout(10, 'ticks', focus_watcher)
        return
    end

    local focus_str = type(focus) == 'table' and table.concat(focus, '/') or tostring(focus)

    if focus_str ~= _last_focus then
        _last_focus = focus_str

        -- Unit view detection
        if focus_str:find('unitview') or focus_str:find('unit_view') then
            local unit = get_cursor_unit()
            local uid = unit and unit.id or nil
            if unit and uid ~= _last_unit then
                _last_unit   = uid
                _last_engpos = nil
                fire_unit_overlay(unit)
            end

        -- Engraving inspect detection
        elseif focus_str:find('engraving') or focus_str:find('tile_inspect') then
            local cursor = guidm.getCursorPos and guidm.getCursorPos()
            if cursor then
                local ckey = engraving_cache_key(cursor)
                local last_key = _last_engpos and engraving_cache_key(_last_engpos) or nil
                if ckey ~= last_key then
                    _last_unit   = nil
                    _last_engpos = cursor
                    fire_engraving_overlay(cursor)
                end
            end
        else
            -- Reset trackers when leaving relevant screens
            _last_unit   = nil
            _last_engpos = nil
        end
    end

    dfhack.timeout(10, 'ticks', focus_watcher)
end

-- ─── Boot ─────────────────────────────────────────────────────────────────────

ensure_dir(IPC_CONTEXT_DIR)
ensure_dir(IPC_RESPONSES_DIR)

focus_watcher()
poll_overlays()

dfhack.print('[dfai] screen_overlay loaded\n')

return {
    fire_unit_overlay    = fire_unit_overlay,
    fire_engraving_overlay = fire_engraving_overlay,
}
