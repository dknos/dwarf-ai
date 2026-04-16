-- eavesdrop_view.lua
-- Phase 5: Dwarf-to-Dwarf Eavesdrop UI
--
-- Keybind (E) in tavern/meeting area: open eavesdrop view.
-- Polls ipc/responses/ for d2d_* response files matching the
-- player's current location.  Renders multi-line conversation
-- in a DFHack GUI window with CP437 box-drawing borders.
--
-- IPC base: /home/nemoclaw/dwarf-ai/lua/ipc/

local json    = require('json')
local gui     = require('gui')
local guidm   = require('gui.dwarfmode')

local IPC_RESPONSES_DIR = '/home/nemoclaw/dwarf-ai/lua/ipc/responses'
local POLL_TICKS        = 15     -- ticks between response-dir polls
local PANEL_WIDTH       = 46     -- inner text width
local MAX_LINES         = 14     -- max dialogue lines shown
local FADE_TICKS        = 600    -- auto-dismiss after ~10 seconds (60 ticks/sec DF)

-- ─── Helpers ──────────────────────────────────────────────────────────────────

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

local function read_json(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local raw = f:read('*all')
    f:close()
    if not raw or raw == '' then return nil end
    local ok, data = pcall(function() return json.decode(raw) end)
    return ok and data or nil
end

local function list_d2d_files()
    -- Returns a list of full paths to d2d_*.json files in responses dir.
    local files = {}
    if not (dfhack.filesystem and dfhack.filesystem.listdir) then
        return files
    end
    local ok, listing = pcall(function()
        return dfhack.filesystem.listdir(IPC_RESPONSES_DIR)
    end)
    if not ok or not listing then return files end
    for _, fname in ipairs(listing) do
        if fname:match('^d2d_') and fname:match('%.json$') then
            table.insert(files, IPC_RESPONSES_DIR .. '/' .. fname)
        end
    end
    return files
end

local function get_current_location()
    -- Best-effort current zone label for location matching.
    -- Returns a lowercase string like "tavern", "meeting_hall", etc.
    local ok_v, zone = pcall(function()
        local cursor = guidm.getCursorPos and guidm.getCursorPos()
        if not cursor then return nil end
        local ok_z, zones = pcall(function()
            return df.global.world.buildings.other.ANY_ZONE
        end)
        if not ok_z or not zones then return nil end
        for _, bld in ipairs(zones) do
            local ok_p1, x1 = pcall(function() return bld.x1 end)
            local ok_p2, x2 = pcall(function() return bld.x2 end)
            local ok_p3, y1 = pcall(function() return bld.y1 end)
            local ok_p4, y2 = pcall(function() return bld.y2 end)
            local ok_pz, bz = pcall(function() return bld.z  end)
            if ok_p1 and ok_p2 and ok_p3 and ok_p4 and ok_pz then
                if cursor.x >= x1 and cursor.x <= x2 and
                   cursor.y >= y1 and cursor.y <= y2 and
                   cursor.z == bz then
                    -- Try to read the building type name
                    local ok_t, btype = pcall(function()
                        return df['civzone_type'][bld.type]
                    end)
                    if ok_t and btype then
                        return tostring(btype):lower()
                    end
                end
            end
        end
        return nil
    end)
    if ok_v and zone then return zone end
    return 'unknown'
end

local function word_wrap(text, max_w)
    -- Splits text on \n and word-wraps each line to max_w chars.
    local result = {}
    if not text or text == '' then return result end
    for para in (text .. '\n'):gmatch('([^\n]*)\n') do
        if #para == 0 then
            table.insert(result, '')
        else
            local i = 1
            while i <= #para do
                local chunk = para:sub(i, i + max_w - 1)
                if #chunk == max_w and i + max_w <= #para then
                    -- Back-off to last space
                    local sp = chunk:match('.*()%s')
                    if sp and sp > 1 then
                        chunk = para:sub(i, i + sp - 2)
                    end
                end
                table.insert(result, chunk)
                i = i + #chunk
                if para:sub(i, i) == ' ' then i = i + 1 end
            end
        end
    end
    return result
end

-- ─── Eavesdrop screen ─────────────────────────────────────────────────────────

local EavesdropScreen = defclass(EavesdropScreen, gui.Screen)
EavesdropScreen.ATTRS {
    focus_path  = 'dfai/eavesdrop',
    dialogue    = '',         -- raw multi-line conversation string
    location    = '',
    speaker_a   = '',
    speaker_b   = '',
    _age_ticks  = 0,
}

-- CP437 box-drawing characters
local BOX_TL = string.char(218)   -- ┌
local BOX_TR = string.char(191)   -- ┐
local BOX_BL = string.char(192)   -- └
local BOX_BR = string.char(217)   -- ┘
local BOX_H  = string.char(196)   -- ─
local BOX_V  = string.char(179)   -- │

function EavesdropScreen:init()
    self._age_ticks = 0
end

function EavesdropScreen:onRenderFrame(dc, rect)
    self:renderParent()

    self._age_ticks = (self._age_ticks or 0) + 1

    local inner_w  = PANEL_WIDTH
    local border_w = inner_w + 4   -- 2 padding each side
    local screen_w, screen_h = dfhack.screen.getWindowSize()

    -- Prepare content lines
    local raw_dialogue = self.dialogue or ''
    local content_lines = word_wrap(raw_dialogue, inner_w)

    -- Clamp to MAX_LINES
    local shown = {}
    for i = 1, math.min(MAX_LINES, #content_lines) do
        shown[#shown + 1] = content_lines[i]
    end
    if #content_lines > MAX_LINES then
        shown[#shown] = shown[#shown]:sub(1, inner_w - 3) .. '...'
    end

    -- Header line
    local loc = self.location or 'somewhere'
    local header = '[You overhear, in ' .. loc .. ']'
    if #header > inner_w then
        header = header:sub(1, inner_w)
    end

    -- Total panel height: top border + header + blank + lines + blank + hint + bottom border
    local panel_h = 2 + 1 + 1 + #shown + 1 + 1 + 1
    if panel_h < 7 then panel_h = 7 end

    -- Centre panel horizontally, place near bottom
    local px = math.floor((screen_w - border_w) / 2)
    local py = screen_h - panel_h - 3
    if py < 1 then py = 1 end

    -- Background fill
    for row = 0, panel_h - 1 do
        dc:seek(px, py + row):string(string.rep(' ', border_w), COLOR_BLACK)
    end

    -- Top border
    dc:seek(px, py):string(BOX_TL, COLOR_GREY)
    dc:string(string.rep(BOX_H, border_w - 2), COLOR_GREY)
    dc:string(BOX_TR, COLOR_GREY)

    -- Side borders
    for row = 1, panel_h - 2 do
        dc:seek(px, py + row):string(BOX_V, COLOR_GREY)
        dc:seek(px + border_w - 1, py + row):string(BOX_V, COLOR_GREY)
    end

    -- Bottom border
    dc:seek(px, py + panel_h - 1):string(BOX_BL, COLOR_GREY)
    dc:string(string.rep(BOX_H, border_w - 2), COLOR_GREY)
    dc:string(BOX_BR, COLOR_GREY)

    -- Header text (yellow, centred in border)
    local hx = px + math.floor((border_w - #header) / 2)
    dc:seek(hx, py):string(header, COLOR_YELLOW)

    -- Blank line
    local row = py + 1

    -- Dialogue lines
    for i, line in ipairs(shown) do
        -- Colour speaker names distinctly
        local color = COLOR_LIGHTGREY
        local sa = self.speaker_a or ''
        local sb = self.speaker_b or ''
        if sa ~= '' and line:sub(1, #sa + 1) == sa .. ':' then
            color = COLOR_WHITE
        elseif sb ~= '' and line:sub(1, #sb + 1) == sb .. ':' then
            color = COLOR_CYAN
        end
        dc:seek(px + 2, row + i):string(line, color)
    end

    -- Dismiss hint
    local hint = '[ESC / E to close]'
    local hint_row = py + panel_h - 2
    dc:seek(px + math.floor((border_w - #hint) / 2), hint_row)
       :string(hint, COLOR_DARKGREY)
end

function EavesdropScreen:onInput(keys)
    if keys.LEAVESCREEN or keys.LEAVESCREEN_ALL then
        self:dismiss()
        return true
    end
    -- Also close on the same keybind that opened it (E / custom_dfai_eavesdrop)
    if keys.CUSTOM_E or keys.CUSTOM_SHIFT_E then
        self:dismiss()
        return true
    end
    return self:passInputToParent(keys)
end

function EavesdropScreen:onTick()
    if self._age_ticks >= FADE_TICKS then
        self:dismiss()
    end
end

-- ─── Public API ───────────────────────────────────────────────────────────────

local _active_screen = nil

local function open_eavesdrop()
    -- Dismiss any already-open eavesdrop screen
    if _active_screen and _active_screen:isActive() then
        _active_screen:dismiss()
        _active_screen = nil
        return
    end

    local current_loc = get_current_location()

    -- Scan d2d response files for one matching this location
    local d2d_files = list_d2d_files()

    local best_data = nil
    for _, fpath in ipairs(d2d_files) do
        local data = read_json(fpath)
        if data then
            local file_loc = tostring(data.location or ''):lower()
            -- Accept if location matches or we can't determine location
            if current_loc == 'unknown' or file_loc == 'unknown' or
               file_loc == current_loc or
               file_loc:find(current_loc, 1, true) or
               current_loc:find(file_loc, 1, true) then
                best_data = data
                break
            end
        end
    end

    if not best_data then
        -- No relevant conversation found — show notice and bail
        dfhack.gui.showAnnouncement(
            '[dfai] No conversations nearby.',
            COLOR_GREY, false
        )
        return
    end

    -- Extract speaker names from unit_a / unit_b if present
    local ua = best_data.unit_a or {}
    local ub = best_data.unit_b or {}
    local name_a = tostring(ua.name or '')
    local name_b = tostring(ub.name or '')

    local dialogue = tostring(best_data.dialogue or '*The dwarves fall silent.*')
    local location = tostring(best_data.location or current_loc)

    local screen = EavesdropScreen {
        dialogue  = dialogue,
        location  = location,
        speaker_a = name_a,
        speaker_b = name_b,
    }
    screen:show()
    _active_screen = screen
end

-- ─── Keybind registration ─────────────────────────────────────────────────────
-- Register dfai-eavesdrop keybind if it has not already been registered.
-- The preferred key is E.  In dfhack-config/dfai.keybindings add:
--   keybinding add E@dwarfmode/Default scripts/ui/eavesdrop_view dfai-eavesdrop

local _keybind_registered = false

local function maybe_register_keybind()
    if _keybind_registered then return end
    _keybind_registered = true
    -- Use pcall — dfhack.hotkeys may not exist in all versions
    pcall(function()
        dfhack.run_command('keybinding', 'add', 'E@dwarfmode/Default',
            'scripts/ui/eavesdrop_view', 'dfai-eavesdrop')
    end)
end

-- ─── Poll loop — auto-refresh if screen is open ───────────────────────────────

local _poll_counter = 0
local _poll_running = false   -- guard against duplicate poll chains

local function poll()
    _poll_counter = _poll_counter + 1
    if _poll_counter >= POLL_TICKS then
        _poll_counter = 0
        -- Age-out the active screen (onTick is not auto-called in all DFHack builds)
        if _active_screen and _active_screen:isActive() then
            _active_screen:onTick()
        end
    end
    dfhack.timeout(1, 'ticks', poll)
end

-- ─── Boot ─────────────────────────────────────────────────────────────────────

maybe_register_keybind()
if not _poll_running then
    _poll_running = true
    poll()
end

dfhack.print('[dfai] eavesdrop_view loaded (press E in meeting area)\n')

-- When called as a script (not required), open immediately.
-- This allows: dfhack.run_command('scripts/ui/eavesdrop_view')
if not dfhack.internal.getModuleIndex then
    -- Running as a top-level script, not a require()
    open_eavesdrop()
end

return {
    open = open_eavesdrop,
}
