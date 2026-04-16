-- dfai_overlay.lua
-- Adds a "Talk (AI)" button to the unit view so the player can click an NPC
-- and start a conversation without needing the launcher or hotkey.
--@module = true

local overlay = require('plugins.overlay')
local widgets = require('gui.widgets')

local function start_chat()
    -- Delegate to the existing context_writer script so all logic stays in one place.
    dfhack.run_script('dfai/context_writer')
end

-- Fortress-mode unit view (right-click a dwarf → ViewSheets/UNIT)
TalkFortOverlay = defclass(TalkFortOverlay, overlay.OverlayWidget)
TalkFortOverlay.ATTRS{
    desc            = 'Adds a Talk (AI) button to the unit sheet.',
    default_enabled = true,
    viewscreens     = 'dwarfmode/ViewSheets/UNIT',
    default_pos     = { x = -33, y = 5 },
    frame           = { w = 18, h = 1 },
}

function TalkFortOverlay:init()
    self:addviews{
        widgets.TextButton{
            frame = { t = 0, l = 0, w = 18, h = 1 },
            label = 'Talk (AI) [F9]',
            on_activate = start_chat,
        },
    }
end

-- Adventure mode unit interact panel (pre-conversation, when hovering/selected)
TalkAdvOverlay = defclass(TalkAdvOverlay, overlay.OverlayWidget)
TalkAdvOverlay.ATTRS{
    desc            = 'Adds a Talk (AI) button to adventure-mode unit interactions.',
    default_enabled = true,
    viewscreens     = 'dungeonmode',
    default_pos     = { x = 2, y = 2 },
    frame           = { w = 22, h = 1 },
}

function TalkAdvOverlay:init()
    self:addviews{
        widgets.TextButton{
            frame = { t = 0, l = 0, w = 22, h = 1 },
            label = 'Speak freely (AI) [F9]',
            on_activate = start_chat,
        },
    }
end

function TalkAdvOverlay:preUpdateLayout(parent_rect)
    local sel = dfhack.gui.getSelectedUnit(true)
    self.visible = sel ~= nil
end

-- Inside the DF conversation screen itself: show a prominent AI option at top
TalkConvoOverlay = defclass(TalkConvoOverlay, overlay.OverlayWidget)
TalkConvoOverlay.ATTRS{
    desc            = 'Adds "Speak freely (AI)" to the adventure conversation screen.',
    default_enabled = true,
    viewscreens     = 'dungeonmode/Conversation',
    default_pos     = { x = 2, y = 2 },
    frame           = { w = 22, h = 1 },
}

function TalkConvoOverlay:init()
    self:addviews{
        widgets.TextButton{
            frame = { t = 0, l = 0, w = 22, h = 1 },
            label = 'Speak freely (AI) [F9]',
            on_activate = start_chat,
        },
    }
end

OVERLAY_WIDGETS = {
    talk_fort  = TalkFortOverlay,
    talk_adv   = TalkAdvOverlay,
    talk_convo = TalkConvoOverlay,
}
