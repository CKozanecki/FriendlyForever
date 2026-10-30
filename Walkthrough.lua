-- The walkthrough (#47): a short tour of the main settings, a step at a
-- time, opening each page. It starts by itself on a first install, can be
-- skipped, and is replayed from the Start here page.
--
-- It only shows and explains settings; it never changes one. Skipping or
-- finishing it is remembered (db.walkthrough, Config.lua). It closes when a
-- fight starts, and one asked for in a fight waits for the fight to end.
local _, ns = ...

local Walkthrough = {}
ns.Walkthrough = Walkthrough

Walkthrough.NAME = "FriendlyForeverWalkthrough"

local frame
local step          -- the step shown, or nil while closed
local pending       -- asked for in a fight: starts when it ends

-- What a setting reads as, from a settings section that may be damaged.
local function Section(name)
    return type(ns.db[name]) == "table" and ns.db[name] or {}
end

local function OnOff(value)
    return value == true and "|cff00ff00on|r" or "|cffff4040off|r"
end

local function KeyText()
    return ns.BuffMode.KeyText((ns.BuffMode.Key()))
end

-- Each step: its title, its text (worked out when shown, from the settings
-- as they are), and the page it opens, if any.
Walkthrough.STEPS = {
    {
        title = "Welcome to Friendly Forever",
        text = function()
            return "It greets guildmates, welcomes new guild and party members, and thanks people who buff you. "
                .. "This short walkthrough shows the main settings, a page at a time.\n\n"
                .. "It only shows and explains: it never changes a setting. Skip it if you like; it's on the "
                .. "Start here page whenever you want it (Esc > Options > AddOns > Friendly Forever)."
        end,
    },
    {
        title = "Buff Back: buff order and \"Never offer\"",
        open = function() ns.Options.OpenTab("buffBack", "buffOrderHeader") end,
        text = function()
            return "When someone outside your group buffs you, a button offers to buff them back. It casts only "
                .. "when you press it.\n\n"
                .. "The buff order says which of your buffs it offers first: the first that suits them. Move a "
                .. "buff with Up and Down, and tick \"Never offer\" for any you never want offered."
        end,
    },
    {
        title = "Buff mode: its key",
        open = function() ns.Options.OpenTab("buffBack", "buffModeKey") end,
        text = function()
            return "Buff mode lends a key to the buff-back button, so you can buff a whole group quickly. "
                .. "Your buff mode key is " .. KeyText() .. " (the mouse wheel unless you've changed it).\n\n"
                .. "Change it with the \"Buff mode key\" button. When buff mode ends, the key does its usual job "
                .. "again."
        end,
    },
    {
        title = "Buff mode: when it turns on and off",
        open = function() ns.Options.OpenTab("buffBack", "autoHeader") end,
        text = function()
            local cfg = Section("buffBack")
            local text = ns.Options.AUTO_TEXT
            local lines = { "Buff mode turns on by itself, and borrows your key, at these times. Each has its "
                .. "switch under \"Buff mode turns on by itself\"; untick any you don't want.", "" }
            local function Row(field) lines[#lines + 1] = "  " .. text[field] .. ": " .. OnOff(cfg[field]) end
            lines[#lines + 1] = "Turns on:"
            Row("autoOnJoin")
            Row("autoOnDeath")
            Row("autoOnBuffed")
            lines[#lines + 1] = "Turns off again, if it turned itself on:"
            Row("autoOffPull")
            Row("autoOffDone")
            local minutes = tonumber(cfg.autoOffMinutes)
            if minutes and minutes > 0 then
                lines[#lines + 1] = ("  or after %d minutes"):format(minutes)
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Buff mode never casts by itself: you still press the key for each buff."
            return table.concat(lines, "\n")
        end,
    },
    {
        title = "Thanks",
        open = function() ns.Options.OpenTab("buff", "header") end,
        text = function()
            local style = ns.Options.THANK_STYLE_TEXT[Section("buff").thankStyle]
                or ns.Options.THANK_STYLE_TEXT.message
            return "Buff Thanks thanks people who buff you. You thank them with " .. style .. "; the \"Thank "
                .. "them with\" button changes it.\n\n"
                .. "The lines it says are below. They're used in random order before any repeats; leave a line "
                .. "blank to skip it."
        end,
    },
    {
        title = "Welcome lines",
        open = function() ns.Options.OpenTab("guildJoin", "header") end,
        text = function()
            return "Guild Join welcomes new guild members, and Party Join new party members, each with its own "
                .. "lines. Guild Login and Party Hello greet people too.\n\n"
                .. "Each tab has its own switch, delay and lines; edit any line, or load the fantasy or casual "
                .. "set."
        end,
    },
    {
        title = "That's it",
        open = function() ns.Options.OpenStart() end,
        text = function()
            return "Start here has the settings most people change, your keys, and a link to every other page. "
                .. "Take the walkthrough again from there any time."
        end,
    },
}

local function Fill()
    local info = Walkthrough.STEPS[step]
    local last = step == #Walkthrough.STEPS
    frame.title:SetText(info.title)
    frame.count:SetText(("%d of %d"):format(step, #Walkthrough.STEPS))
    frame.text:SetText(info.text())
    -- The text's scrolling area holds all of it, back at its top.
    local height = frame.text:GetStringHeight()
    frame.body:SetHeight(type(height) == "number" and height + 8 or 1)
    frame.scroll:SetVerticalScroll(0)
    frame.back:SetShown(step > 1)
    frame.skip:SetShown(not last)
    frame.next:SetText(last and "Finish" or (step == 1 and "Show me around" or "Next"))
end

local function Show(index)
    step = index
    frame:Show()
    Fill()
    local open = Walkthrough.STEPS[step].open
    if open then open() end
end

-- Closes it, remembering result ("skipped" or "done") when given.
local function Close(result)
    step = nil
    if result then ns.db.walkthrough = result end
    frame:Hide()
end

local function Create()
    frame = CreateFrame("Frame", Walkthrough.NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(460, 240)
    -- Low on the screen but clear of the action bars, over the bottom of
    -- the options, whose rows it scrolls to the top. Above the options
    -- window.
    frame:SetPoint("BOTTOM", 0, 110)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    -- The template's close button skips, as the Skip button does.
    if type(frame.CloseButton) == "table" then
        frame.CloseButton:SetScript("OnClick", function() Walkthrough.Skip() end)
    end

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOPLEFT", 12, -5)
    frame.title:SetPoint("RIGHT", -96, 0)
    frame.title:SetJustifyH("LEFT")
    frame.title:SetWordWrap(false)
    frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.count:SetPoint("TOPRIGHT", -32, -7)

    -- The step's text scrolls, so a long one (or a font wider than
    -- expected) never runs past the buttons.
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -34)
    scroll:SetPoint("BOTTOMRIGHT", -34, 44)
    frame.scroll = scroll
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(400, 1)
    scroll:SetScrollChild(body)
    frame.body = body
    frame.text = body:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    -- Pinned on both sides of the area, so it wraps at its width.
    frame.text:SetPoint("TOPLEFT", 0, 0)
    frame.text:SetPoint("TOPRIGHT", 0, 0)
    frame.text:SetJustifyH("LEFT")
    frame.text:SetWordWrap(true)

    local function Button(text, width, onClick)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(width, 22)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end
    frame.next = Button("Next", 130, function() Walkthrough.Next() end)
    frame.next:SetPoint("BOTTOMRIGHT", -14, 12)
    frame.back = Button("Back", 80, function() Walkthrough.Back() end)
    frame.back:SetPoint("RIGHT", frame.next, "LEFT", -8, 0)
    frame.skip = Button("Skip the walkthrough", 160, function() Walkthrough.Skip() end)
    frame.skip:SetPoint("BOTTOMLEFT", 14, 12)

    -- It closes as a fight starts, and one asked for in a fight starts
    -- once the fight is over.
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:SetScript("OnEvent", ns.Diag.Wrap(function(_, event)
        if event == "PLAYER_REGEN_DISABLED" and step then
            Close()
            ns.Print("walkthrough closed for the fight. Take it again from the Start here page.")
        elseif event == "PLAYER_REGEN_ENABLED" and pending then
            Walkthrough.Start()
        end
    end))
end

function Walkthrough.Create()
    if not frame then Create() end
end

-- Starts it at the first step, or once the fight is over when in one.
function Walkthrough.Start()
    if InCombatLockdown() then
        if not pending then ns.Print("the walkthrough will start when this fight is over.") end
        pending = true
        return
    end
    pending = false
    Show(1)
end

function Walkthrough.Next()
    if not step then return end
    if step == #Walkthrough.STEPS then return Close("done") end
    Show(step + 1)
end

function Walkthrough.Back()
    if step and step > 1 then Show(step - 1) end
end

function Walkthrough.Skip()
    pending = false
    Close("skipped")
end

-- At login: on a first install, say where Start here is and start the
-- walkthrough. Once it's been skipped or finished, nothing.
function Walkthrough.OnLogin()
    if ns.db.walkthrough ~= "new" then return end
    ns.Print("welcome! The Start here page has the settings most people change: Esc > Options > AddOns > "
        .. ns.TITLE .. " > Start here.")
    Walkthrough.Start()
end

function Walkthrough.Step() return step end
function Walkthrough.IsPending() return pending == true end
function Walkthrough.Frame() return frame end
