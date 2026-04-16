-- chat_view.lua
--@module = true
-- Persistent conversation panel — shows full history with the current NPC,
-- an input box at the bottom, and streams new turns without dismissing.

local gui     = require('gui')
local widgets = require('gui.widgets')

ChatView = defclass(ChatView, gui.ZScreen)
ChatView.ATTRS {
    focus_path = 'dfai-chat',
    modal      = false,
    unit_id    = -1,
    npc_name   = 'Unknown',
    on_submit  = DEFAULT_NIL,  -- callback(text) → sends context file
}

function ChatView:init()
    self._turns = {}  -- {{who='You'|'NPC', text=...}, ...}

    self:addviews{
        widgets.Window{
            frame_title = 'Talk — ' .. self.npc_name,
            frame = { w = 70, h = 20 },
            resizable = true,
            subviews = {
                widgets.WrappedLabel{
                    view_id = 'transcript',
                    frame = { t = 0, l = 0, r = 0, b = 3 },
                    text_to_wrap = function() return self:_rendered_transcript() end,
                    auto_height = false,
                    scroll_keys = { STANDARDSCROLL_UP = -1, STANDARDSCROLL_DOWN = 1,
                                    STANDARDSCROLL_PAGEUP = '-page', STANDARDSCROLL_PAGEDOWN = '+page' },
                },
                widgets.EditField{
                    view_id = 'input',
                    frame = { b = 1, l = 0, r = 0 },
                    label_text = '> ',
                    on_submit = function(text)
                        if text and text ~= '' then self:_send(text) end
                    end,
                },
                widgets.Label{
                    view_id = 'hint',
                    frame = { b = 0, l = 0 },
                    text = { { text = 'Enter ', pen = COLOR_LIGHTGREEN }, 'send  ',
                             { text = 'Esc ',   pen = COLOR_LIGHTGREEN }, 'close  ',
                             { text = 'PgUp/PgDn', pen = COLOR_LIGHTGREEN }, ' scroll' },
                },
            },
        },
    }
end

function ChatView:_rendered_transcript()
    local out = {}
    for _, t in ipairs(self._turns) do
        if t.who == 'You' then
            table.insert(out, 'You: ' .. t.text)
        else
            table.insert(out, self.npc_name .. ': ' .. t.text)
        end
        table.insert(out, '')
    end
    if #out == 0 then
        return '*Begin by typing what you want to say below.*'
    end
    return table.concat(out, '\n')
end

function ChatView:_send(text)
    table.insert(self._turns, { who = 'You', text = text })
    self.subviews.input:setText('')
    self.subviews.transcript:updateLayout()
    if self.on_submit then
        self.on_submit(text, self)
    end
    -- Add "thinking..." placeholder; will be replaced when response arrives.
    table.insert(self._turns, { who = 'NPC', text = '*thinking...*' })
    self.subviews.transcript:updateLayout()
end

--- Called by response_reader when a reply for this unit arrives.
function ChatView:pushReply(text)
    -- Replace last "thinking..." placeholder
    if #self._turns > 0 and self._turns[#self._turns].who == 'NPC'
            and self._turns[#self._turns].text == '*thinking...*' then
        self._turns[#self._turns].text = text
    else
        table.insert(self._turns, { who = 'NPC', text = text })
    end
    self.subviews.transcript:updateLayout()
end

function ChatView:onDismiss()
    _G.dfai_active_chat = nil
end

-- Singleton helpers
function show(unit_id, npc_name, on_submit)
    if _G.dfai_active_chat and _G.dfai_active_chat.unit_id == unit_id then
        _G.dfai_active_chat:raise()
        return _G.dfai_active_chat
    end
    if _G.dfai_active_chat then
        _G.dfai_active_chat:dismiss()
    end
    local view = ChatView{
        unit_id   = unit_id,
        npc_name  = npc_name,
        on_submit = on_submit,
    }
    view:show()
    _G.dfai_active_chat = view
    return view
end

function active()
    return _G.dfai_active_chat
end
