-- The only place the addon sends chat. Every message goes through this
-- queue, which:
--   * rate-limits output (a guild-wide login wave can't flood chat),
--   * bounds how much can be waiting and how long it may wait,
--   * holds messages while the game's chat lockdown is active,
--   * holds /say outside instances until a hardware event (key press),
--     which the game requires for that channel,
--   * re-checks each message is still wanted right before sending.
local _, ns = ...

local ChatQueue = {}
ns.ChatQueue = ChatQueue

ChatQueue.MIN_INTERVAL = 1.5  -- seconds between any two sends
ChatQueue.MAX_PENDING = 25
ChatQueue.MAX_AGE = 120       -- seconds a message may wait before it is dropped
ChatQueue.RETRY_DELAY = 2

local pending = {}
local lastSendTime = -math.huge
local pumpScheduled = false
local waitingForHardware = false
local keyFrame
local keyboardReady = false

function ChatQueue.InChatLockdown()
    local info = C_ChatInfo
    return info ~= nil and info.InChatMessagingLockdown ~= nil and info.InChatMessagingLockdown() == true
end

function ChatQueue.NeedsHardwareEvent(channel)
    if channel ~= "SAY" and channel ~= "YELL" then return false end
    return not IsInInstance()
end

local function RawSend(text, channel, target)
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    return pcall(send, text, channel, nil, target)
end

local function Finish(item, sent)
    if item.onDone then item.onDone(sent) end
end

local function Drop(item, reason)
    ns.Diag.Count("dropped")
    ns.Diag.Log("send", "dropped %s: %s", item.label, reason)
    Finish(item, false)
end

-- Log why a message is waiting, once per reason change (not every pump).
local function Hold(item, reason)
    if item.heldReason == reason then return end
    item.heldReason = reason
    ns.Diag.Log("send", "holding %s: %s", item.label, reason)
end

local function ResolveChannel(item)
    if type(item.channel) == "function" then return item.channel() end
    return item.channel
end

local SchedulePump

-- Send at most one message. `hardware` is true when called from a key press.
function ChatQueue.Pump(hardware)
    local now = GetTime()
    local sent = false
    local needsHardware = false
    local i = 1

    while i <= #pending do
        local item = pending[i]
        local channel = ResolveChannel(item)

        local dropReason
        if now - item.created > ChatQueue.MAX_AGE then
            dropReason = "waited too long (" .. ChatQueue.MAX_AGE .. "s)"
        elseif not channel then
            dropReason = "no channel (not in a guild/group any more?)"
        elseif channel == "WHISPER" and type(item.target) ~= "string" then
            dropReason = "whisper without a target"
        else
            local valid, why = true, nil
            if item.isValid then valid, why = item.isValid() end
            if not valid then dropReason = "no longer wanted: " .. (why or "no reason given") end
        end

        if dropReason then
            table.remove(pending, i)
            Drop(item, dropReason)
        elseif sent or now - lastSendTime < ChatQueue.MIN_INTERVAL then
            if ChatQueue.NeedsHardwareEvent(channel) then needsHardware = true end
            i = i + 1
        elseif ChatQueue.InChatLockdown() then
            Hold(item, "game chat lockdown is active")
            if ChatQueue.NeedsHardwareEvent(channel) then needsHardware = true end
            i = i + 1
        elseif ChatQueue.NeedsHardwareEvent(channel) and not hardware then
            Hold(item, channel .. " outdoors needs a key press")
            needsHardware = true
            i = i + 1
        else
            table.remove(pending, i)
            local text = item.getText()
            if text == nil then
                Drop(item, "message rendered empty")
            else
                local ok, err = RawSend(text, channel, item.target)
                if ok then
                    lastSendTime = now
                    sent = true
                    ns.Diag.Count("sent")
                    ns.Diag.Log("send", "sent %s to %s%s: %s", item.label, channel,
                        item.target and (" " .. item.target) or "", text)
                    Finish(item, true)
                else
                    ns.Diag.Count("sendErrors")
                    ns.Diag.Log("send", "ERROR sending %s to %s: %s", item.label, channel, err)
                    Finish(item, false)
                end
            end
        end
    end

    waitingForHardware = needsHardware
    if #pending > 0 then SchedulePump() end
end

SchedulePump = function()
    if pumpScheduled then return end
    pumpScheduled = true
    local wait = ChatQueue.MIN_INTERVAL - (GetTime() - lastSendTime)
    if wait < 0.1 or wait > ChatQueue.RETRY_DELAY then wait = ChatQueue.RETRY_DELAY end
    C_Timer.After(wait, ns.Diag.Wrap(function()
        pumpScheduled = false
        ChatQueue.Pump(false)
    end))
end

-- item = {
--   channel  = "GUILD" | function() -> channel or nil,
--   target   = player name to whisper when channel is WHISPER,
--   getText  = function() -> text or nil (called right before sending),
--   isValid  = optional function() -> ok, reason (reason is logged when not ok),
--   onDone   = optional function(sent),
--   label    = optional text naming the message in diagnostics,
-- }
function ChatQueue.Push(item)
    item.label = item.label or "message"
    if #pending >= ChatQueue.MAX_PENDING then
        Drop(item, "queue full")
        return false
    end
    ns.Diag.Count("queued")
    ns.Diag.Log("send", "queued %s", item.label)
    item.created = GetTime()
    pending[#pending + 1] = item
    ChatQueue.Pump(false)
    return true
end

function ChatQueue.Count()
    return #pending
end

function ChatQueue.IsWaitingForHardware()
    return waitingForHardware
end

function ChatQueue.IsKeyboardReady()
    return keyboardReady
end

function ChatQueue.OnHardwareEvent()
    if waitingForHardware then ChatQueue.Pump(true) end
end

-- Listen for key presses (they still reach the game: input propagates) so a
-- press can serve as the hardware event /say needs. SetPropagateKeyboardInput
-- is not allowed in combat, so set it up afterwards if we load mid-fight.
function ChatQueue.Init()
    if keyFrame then return end
    keyFrame = CreateFrame("Frame", nil, UIParent)
    -- Give it a size and position so it counts as visible; it takes no mouse input.
    keyFrame:SetSize(1, 1)
    keyFrame:SetPoint("TOPLEFT")
    keyFrame:SetScript("OnKeyDown", ns.Diag.Wrap(ChatQueue.OnHardwareEvent))

    local function EnableKeys()
        keyFrame:EnableKeyboard(true)
        keyFrame:SetPropagateKeyboardInput(true)
        keyboardReady = true
    end
    if InCombatLockdown() then
        keyFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        keyFrame:SetScript("OnEvent", function(self)
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            EnableKeys()
        end)
    else
        EnableKeys()
    end
end
