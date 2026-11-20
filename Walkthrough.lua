-- The walkthrough (#47): a short tour of the main settings, a step at a
-- time, opening each page. It starts by itself at login until it has been
-- finished or skipped (db.walkthrough, Config.lua), and is replayed from the
-- Start here page.
--
-- On a new install it's first-run setup: the addon is off until the
-- walkthrough is finished or skipped, and either turns it on. Switching the
-- addon on or off by hand ends first run (ns.SetEnabled calls EndFirstRun).
-- For someone already using the addon it shows once and changes nothing.
-- Otherwise it only shows and explains settings. Finishing and skipping are
-- handled in Close only. A fight closes it, and it reopens at the same step
-- when the fight is over; one asked for in a fight waits for the fight to
-- end (the owner's decisions on #47).
--
-- What's new (#169): each step records the walkthrough version it was added
-- in (since). After an update that raised Config.WALKTHROUGH_VERSION, a
-- player who finished or skipped an older version sees only the steps newer
-- than it, titled "What's new"; a new player, or the replay from Start here,
-- sees every step. Finishing or skipping saves the current version, and
-- never turns the addon on or off.
--
-- The one exception to "it changes no setting" (#408): the step about the
-- Buffs tab offers the player's choice of how their buff rules start, while
-- it is still to be made (BuffRules.Pending). Its two buttons call
-- BuffRules.Choose, as the Buffs tab's do, and only a press chooses:
-- Next, Back, Skip, closing and a fight leave the choice waiting on the tab.
local _, ns = ...

local Walkthrough = {}
ns.Walkthrough = Walkthrough

Walkthrough.NAME = "FriendlyForeverWalkthrough"

local frame
local steps         -- the steps of this run, in order (every step, or just the new ones)
local whatsNew      -- whether this run is only the steps added since the player last finished
local step          -- the step shown (an index into steps), or nil while closed
local pending       -- the step to show when the fight is over, or nil

-- What a setting reads as, from a settings section that may be damaged.
local function Section(name)
    return type(ns.db[name]) == "table" and ns.db[name] or {}
end

local function OnOff(value)
    return value == true and ns.Colours.Text("good", "on") or ns.Colours.Text("bad", "off")
end

-- How many buffs have a rule of their own in 1.3.3's settings
-- (buffBack.whoGets: a buff is saved there only once changed, #219), from
-- settings that may be damaged: your class's, and the rest. The settings
-- are shared by every character on the account (Config.lua), so the rest
-- are rules changed on your other characters, which the choice covers too.
-- A key kept known without a buff (BuffTable.absent, #209) isn't counted.
local function RulesChanged()
    local saved = Section("buffBack").whoGets
    if type(saved) ~= "table" then return 0, 0 end
    local mine, theirs = 0, 0
    local own = {}
    for _, buff in ipairs(ns.BuffData.ClassBuffs()) do own[buff.key] = true end
    for key, rule in pairs(saved) do
        if type(rule) == "table" and type(key) == "string" and ns.BuffData.ByKey(key) then
            if own[key] then mine = mine + 1 else theirs = theirs + 1 end
        end
    end
    return mine, theirs
end

-- Whether the step shown offers the choice of how buff rules start (#408).
local function Choosing(info)
    return info.choice == true and ns.BuffRules.Pending()
end

local function KeyText()
    return ns.BuffMode.KeyText((ns.BuffMode.Key()))
end

-- The saved state as Config.lua checks it, whatever damage it has had.
local function State()
    return ns.Config.ValidWalkthrough(ns.db.walkthrough)
end

-- Whether this is a new install's first run, which ends by turning the addon on.
function Walkthrough.FirstRun() return State().firstRun end

-- Each step: the walkthrough version it was added in (since: 1 for the
-- first, raised by hand in Config.lua together with Config.WALKTHROUGH_VERSION
-- when a release adds a step, see CONTRIBUTING.md), its title, its text
-- (worked out when shown, from the settings as they are), and the page it
-- opens, if any.
Walkthrough.STEPS = {
    {
        since = 1,
        title = "Welcome to Friendly Forever",
        text = function()
            local first = Walkthrough.FirstRun() and ("Friendly Forever is off until you finish or skip this "
                .. "walkthrough; either turns it on.\n\n") or ""
            return "It greets guildmates, welcomes new guild and party members, and thanks people who buff you. "
                .. "This short walkthrough shows the main settings, a page at a time.\n\n" .. first
                .. "It only shows and explains: it changes no setting. Skip it if you like; it's on the "
                .. "Start here page whenever you want it (Esc > Options > AddOns > Friendly Forever)."
        end,
    },
    {
        since = 1,
        title = "Buffs: buff order and \"Never offer\"",
        open = function() ns.Options.OpenTab(ns.Options.BUFFS_TAB, "buffOrderHeader") end,
        text = function()
            return "When someone outside your group buffs you, a button offers to buff them back. It casts only "
                .. "when you press it.\n\n"
                .. "On the Buffs tab, the buff order says which of your buffs it offers first: the first that "
                .. "suits them. Move a buff with Up and Down, and tick \"Never offer\" for any you never want "
                .. "offered. Below, who gets each buff: Strangers (who buff you, or pass by), Party, Raid and PvP "
                .. "each have their own."
        end,
    },
    {
        since = 1,
        title = "Buff mode: its key",
        open = function() ns.Options.OpenTab(ns.Options.BUFFS_TAB, "buffModeKey") end,
        text = function()
            return "Buff mode lends a key to the buff button, so you can buff a whole group quickly. "
                .. "Your buff mode key is " .. KeyText() .. " (the mouse wheel unless you've changed it).\n\n"
                .. "Change it with the \"Buff mode key\" button. When buff mode ends, the key does its usual job "
                .. "again."
        end,
    },
    {
        since = 1,
        title = "Buff mode: when it turns on and off",
        open = function() ns.Options.OpenTab(ns.Options.BUFFS_TAB, "autoHeader") end,
        text = function()
            local cfg = Section("buffBack")
            local text = ns.Options.AUTO_TEXT
            -- That it never casts comes first, so it stays in view above the list (#272).
            local lines = { "Buff mode turns on by itself, and borrows your key, at these times. Each has its "
                .. "switch under \"Buff mode turns on by itself\"; untick any you don't want. It never casts "
                .. "by itself: you still press the key for each buff.", "" }
            local function Row(field) lines[#lines + 1] = "  " .. text[field] .. ": " .. OnOff(cfg[field]) end
            lines[#lines + 1] = "Turns on:"
            Row("autoOnJoin")
            Row("autoOnDeath")
            Row("autoOnBuffed")
            Row("autoOnMissing")
            Row("autoOnCampfire")
            lines[#lines + 1] = "Turns off again, if it turned itself on:"
            Row("autoOffPull")
            Row("autoOffDone")
            local minutes = tonumber(cfg.autoOffMinutes)
            if minutes and minutes > 0 then
                lines[#lines + 1] = ("  or after %d minutes"):format(minutes)
            end
            return table.concat(lines, "\n")
        end,
    },
    {
        since = 1,
        title = "Thanks",
        open = function() ns.Options.OpenTab("buff", "thanksHeader") end,
        text = function()
            local style = ns.Options.THANK_STYLE_TEXT[Section("buff").thankStyle]
                or ns.Options.THANK_STYLE_TEXT.message
            return "The Favours tab thanks people who buff you. You thank them with " .. style .. "; the \"Thank "
                .. "them with\" button changes it.\n\n"
                .. "The lines it says are under \"Thank-you lines\" at the bottom. They're used in random order "
                .. "before any repeats; leave a line blank to skip it."
        end,
    },
    {
        since = 1,
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
        -- Buff requests in chat (#40): off by default, so a returning
        -- player hears it exists and how to turn it on (the owner's decision).
        since = 2,
        title = "Buff requests in chat",
        open = function() ns.Options.OpenTab(ns.Options.FAVOURS_TAB, "buffRequests") end,
        text = function()
            return "Players can ask for your buffs in chat. When someone whispers you, or says in /say or "
                .. "party chat, a short request such as \"mark pls\" or \"can I get int?\", the buff button "
                .. "offers them that buff. "
                .. "It never casts by itself: you still press the button. Nothing is said in chat.\n\n"
                .. "It's off unless you turn it on: tick \"" .. ns.Requests.LABEL .. "\" on the Favours tab. "
                .. "It's " .. OnOff(Section("buffBack").requests) .. " now. Your ignore list, snooze and the "
                .. "quiet in capital cities and battlegrounds apply."
        end,
    },
    {
        -- Who gets each buff, by place (#408): the Buffs tab, and the
        -- player's choice of how their rules start (the owner's decisions).
        since = 3,
        title = "Your buffs have a tab of their own",
        choice = true,
        open = function() ns.Options.OpenTab(ns.Options.BUFFS_TAB, "buffsHeader") end,
        text = function()
            local lines = { "Who gets each buff now has its own rules for Strangers, Party, Raid and "
                .. "PvP (battlegrounds and arenas): by role (Tanks, Healers, Damage), class or name. In PvP every "
                .. "buff is off unless you turn it on. They're on the new Buffs tab.", "" }
            local choice = ns.BuffRules.Choice()
            if choice == "pending" then
                local mine, theirs = RulesChanged()
                local function Buffs(n) return n == 1 and "1 buff" or n .. " buffs" end
                if mine + theirs == 0 then
                    lines[#lines + 1] = "You've never changed who gets your buffs, so the new defaults are "
                        .. "recommended."
                elseif theirs == 0 then
                    lines[#lines + 1] = ("You changed who gets %d of your buffs. How would you like to start?")
                        :format(mine)
                elseif mine == 0 then
                    lines[#lines + 1] = ("You changed who gets %s on your other characters. How would you like "
                        .. "to start?"):format(Buffs(theirs))
                else
                    lines[#lines + 1] = ("You changed who gets %d of your buffs, and %s on your other "
                        .. "characters. How would you like to start?"):format(mine, Buffs(theirs))
                end
                lines[#lines + 1] = "  Keep my settings: your rules go to Party and Raid; PvP starts off."
                lines[#lines + 1] = "  Use the new defaults: recommended if you never changed them, or aren't sure."
                lines[#lines + 1] = "The choice is for all your characters."
                lines[#lines + 1] = ""
                lines[#lines + 1] = "Finishing, skipping or closing without choosing changes nothing: your buffs "
                    .. "work as before until you choose, and the choice waits on the Buffs tab."
            elseif choice == "kept" then
                lines[#lines + 1] = "You kept your settings: your rules apply in Party and Raid, and every buff "
                    .. "starts off in PvP. Change them on the Buffs tab."
            else
                lines[#lines + 1] = "Your buffs use the new defaults. Change them on the Buffs tab."
            end
            return table.concat(lines, "\n")
        end,
    },
    {
        -- Favours (#491): Buff Thanks and Buff Back became one tab, and
        -- passers-by and buff requests moved to it. A returning player is
        -- told where each thing went; a new player sees the tab described.
        since = 4,
        title = "Favours: thanking and buffing back",
        open = function() ns.Options.OpenTab(ns.Options.FAVOURS_TAB, "thanksHeader") end,
        text = function()
            local back = Section("buffBack")
            local said = back.sayLine == true and "on, as you had it" or "off unless you turn it on"
            if Walkthrough.WhatsNew() then
                return "The Buff Thanks and Buff Back tabs are now one tab, Favours. Your settings and lines "
                    .. "are as you left them.\n\n"
                    .. "  Thanking people who buff you: \"When someone buffs you\".\n"
                    .. "  Buffing them back: \"Return the favour\" and \"The buff button\".\n"
                    .. "  Buff requests in chat, and the passers-by switch (from the Buffs tab): \"Asked and "
                    .. "passing by\".\n"
                    .. "  Both sets of lines: \"Thank-you lines\" and \"When my buff lands\".\n\n"
                    .. "Buff mode's key, when it turns on and off, and top-up moved to the Buffs tab, under "
                    .. "\"Buff mode\", where its place \"Buff Back\" is now \"Strangers\". The line said "
                    .. "when your buff lands is " .. said .. "."
            end
            return "Everything about strangers who buff you is on the Favours tab: thanking them, buffing them "
                .. "back, buff requests in chat and passers-by, with the lines for each.\n\n"
                .. "Your thank-you is the one line said for a favour. A line when your buff lands is "
                .. said .. "."
        end,
    },
    {
        -- Each character's own buff settings (#508): weapon buffs were
        -- reset once for every character (the owner), so the step opens
        -- the Weapon buffs page to set them, and names the settings each
        -- character copied. Each character sees it once (character = true:
        -- Walkthrough.OnLogin, Profiles.NeedsWelcome), in the walkthrough,
        -- What's new, or on its own.
        since = 5,
        character = true,
        title = "Each character's own buffs",
        open = function() ns.Options.OpenPage((select(3, ns.Options.Pages()))) end,
        text = function()
            local shared = ns.Profiles.SharedProfile()
            local start
            if shared then
                start = "This character uses the shared profile " .. ns.Util.StripChat(shared) .. ", so these "
                    .. "settings are that profile's, the same for each character on it: its weapon buffs, "
                    .. "here on the Weapon buffs page, and:\n\n"
            elseif Walkthrough.WhatsNew() then
                start = "Weapon buffs are now set for each character, and were reset for every character: set "
                    .. "this character's again here, on the Weapon buffs page.\n\nThese are each character's own "
                    .. "too, and started as a copy of the settings you had: check or change them.\n\n"
            else
                start = "This character's weapon buffs are its own, and start unset: set them here, on the Weapon "
                    .. "buffs page.\n\nThese are its own too, a copy of your settings to start with: check or "
                    .. "change them.\n\n"
            end
            return start
                .. "  The Buffs tab: the buff order and \"Never offer\", who gets each buff in each place, "
                .. "buff mode's key, and \"Offer my self-buffs\".\n\n"
                .. "Everything else is shared by all your characters. A character on a shared profile (the "
                .. "General page's Profiles) uses that profile's settings for these too."
        end,
    },
    {
        since = 1,
        title = "That's it",
        open = function() ns.Options.OpenStart() end,
        text = function()
            local first = Walkthrough.FirstRun() and "Finish turns Friendly Forever on.\n\n" or ""
            return first .. "Start here shows the settings that apply and your keys, with a link to every other "
                .. "page. Take the walkthrough again from there any time."
        end,
    },
}

-- The steps added after a version, in order. A version that is no number
-- gives every step.
function Walkthrough.StepsSince(seen)
    local out = {}
    for _, info in ipairs(Walkthrough.STEPS) do
        if type(seen) ~= "number" or info.since > seen then out[#out + 1] = info end
    end
    return out
end

-- The window's height, and its text area's bottom: taller, with a row for
-- the two choice buttons above the others, while the choice is offered.
local HEIGHT, CHOICE_ROW = 240, 30

local function Fill()
    local info = steps[step]
    local last = step == #steps
    local choosing = Choosing(info)
    frame:SetHeight(HEIGHT + (choosing and CHOICE_ROW or 0))
    frame.scroll:SetPoint("BOTTOMRIGHT", -34, 44 + (choosing and CHOICE_ROW or 0))
    frame.keep:SetShown(choosing)
    frame.new:SetShown(choosing)
    frame.title:SetText((whatsNew and "What's new: " or "") .. info.title)
    frame.count:SetText(("%d of %d"):format(step, #steps))
    frame.stepText:SetText(info.text())
    -- The text's scrolling area holds all of it, back at its top.
    local height = frame.stepText:GetStringHeight()
    frame.body:SetHeight(type(height) == "number" and height + 8 or 1)
    frame.scroll:SetVerticalScroll(0)
    frame.back:SetShown(step > 1)
    frame.skip:SetShown(not last)
    frame.next:SetText(last and "Finish" or (info == Walkthrough.STEPS[1] and "Show me around" or "Next"))
end

local function Show(index)
    step = index
    frame:Show()
    Fill()
    local open = steps[step].open
    if open then open() end
end

-- Closes it. done: it was finished or skipped, so it's seen, and a first
-- run ends by turning the addon on. A run with the step about each
-- character's own settings counts as this character's welcome (#508).
local function Close(done)
    step = nil
    frame:Hide()
    if not done then return end
    for _, info in ipairs(steps) do
        if info.character then ns.Profiles.Welcomed() end
    end
    local first = State().firstRun
    ns.db.walkthrough = { seen = ns.Config.WALKTHROUGH_VERSION, firstRun = false }
    if first then ns.SetEnabled(true) end
end

local function Create()
    frame = CreateFrame("Frame", Walkthrough.NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(460, HEIGHT)
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
    frame.stepText = body:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    -- Pinned on both sides of the area, so it wraps at its width.
    frame.stepText:SetPoint("TOPLEFT", 0, 0)
    frame.stepText:SetPoint("TOPRIGHT", 0, 0)
    frame.stepText:SetJustifyH("LEFT")
    frame.stepText:SetWordWrap(true)

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
    -- The choice of how buff rules start (#408), shown only while offered.
    frame.keep = Button("Keep my settings", 150, function() Walkthrough.Choose("kept") end)
    frame.keep:SetPoint("BOTTOMLEFT", 14, 12 + CHOICE_ROW)
    frame.new = Button("Use the new defaults (recommended)", 240, function() Walkthrough.Choose("new") end)
    frame.new:SetPoint("LEFT", frame.keep, "RIGHT", 8, 0)
    frame.keep:Hide()
    frame.new:Hide()

    -- It closes as a fight starts, and one asked for in a fight starts
    -- once the fight is over.
    frame:RegisterEvent("PLAYER_REGEN_DISABLED")
    frame:RegisterEvent("PLAYER_REGEN_ENABLED")
    frame:SetScript("OnEvent", ns.Diag.Wrap(function(_, event)
        if event == "PLAYER_REGEN_DISABLED" and step then
            pending = step
            Close()
            ns.Print("walkthrough closed for the fight; it comes back when the fight is over.")
        elseif event == "PLAYER_REGEN_ENABLED" and pending then
            local resume = pending
            pending = nil
            Show(resume)
        end
    end))
end

function Walkthrough.Create()
    if not frame then Create() end
end

-- Starts it at the first step, or once the fight is over when in one: every
-- step, or with new set, only those added since the player last finished
-- it, or with new "character", only the step about each character's own
-- settings (#508).
function Walkthrough.Start(new)
    if new == "character" then
        steps = {}
        for _, info in ipairs(Walkthrough.STEPS) do
            if info.character then steps[#steps + 1] = info end
        end
        new = false
    else
        new = new == true
        steps = new and Walkthrough.StepsSince(State().seen) or Walkthrough.STEPS
    end
    whatsNew = new
    if InCombatLockdown() then
        if not pending then ns.Print("the walkthrough will start when this fight is over.") end
        pending = 1
        return
    end
    pending = nil
    Show(1)
end

function Walkthrough.Next()
    if not step then return end
    if step == #steps then return Close(true) end
    Show(step + 1)
end

-- A press of a choice button (#408): "kept" or "new". Only on the step
-- that offers it, while it does. The Buffs tab's own buttons do the same
-- (BuffsTab.Choose: BuffRules.Choose, which makes it once, says in chat
-- what it did and refreshes this step to say so, then the tab shown beside
-- this refreshed). Returns whether the choice is now made.
function Walkthrough.Choose(choice)
    if not step or not Choosing(steps[step]) then return false end
    ns.BuffsTab.Choose(choice)
    return not ns.BuffRules.Pending()
end

-- The choice was made somewhere (here, or the Buffs tab beside it):
-- the step shown says so at once, its buttons gone (BuffRules.Choose).
function Walkthrough.Refresh()
    if step and frame then Fill() end
end

function Walkthrough.Back()
    if step and step > 1 then Show(step - 1) end
end

function Walkthrough.Skip()
    pending = nil
    Close(true)
end

-- At login, until the current version has been finished or skipped: say
-- where Start here is, and start the walkthrough. Someone who finished an
-- older version gets only what's new. Otherwise, a character that hasn't
-- seen the step about its own settings gets that step alone, once (#508).
function Walkthrough.OnLogin()
    local state = State()
    local latest = ns.Config.WALKTHROUGH_VERSION
    local new = state.seen > 0
    local count = #Walkthrough.StepsSince(state.seen)
    if state.seen < latest and new and count == 0 then
        -- A version raised with no step to show: nothing to tell them.
        ns.db.walkthrough = { seen = latest, firstRun = false }
        state = State()
    end
    if state.seen >= latest then
        if ns.Profiles.NeedsWelcome() then
            ns.Print((ns.Profiles.SharedProfile() and "this character uses a shared profile's buff settings"
                or "this character's weapon buffs aren't set yet, and some buff settings are its own")
                .. ": the walkthrough shows where. Esc > Options > AddOns > " .. ns.TITLE .. " > Weapon buffs.")
            Walkthrough.Start("character")
        end
        return
    end
    local intro = state.firstRun and "welcome! Friendly Forever is off until you finish or skip its walkthrough. "
        or new and ("what's new in Friendly Forever: %d new step%s in the walkthrough. "):format(count,
            count == 1 and "" or "s")
        or "new: a short walkthrough of the main settings. "
    ns.Print(intro .. "The Start here page shows your settings: Esc > Options > AddOns > " .. ns.TITLE
        .. " > Start here.")
    Walkthrough.Start(new)
end

-- The addon was switched on or off by hand: that's the player's choice, so
-- finishing the walkthrough no longer switches it.
function Walkthrough.EndFirstRun()
    local state = State()
    state.firstRun = false
    ns.db.walkthrough = state
end

function Walkthrough.Step() return step end
-- How many steps this run has (every step, or the new ones), 0 before any.
function Walkthrough.Count() return steps and #steps or 0 end
function Walkthrough.WhatsNew() return whatsNew == true end
function Walkthrough.IsPending() return pending ~= nil end
function Walkthrough.Frame() return frame end
