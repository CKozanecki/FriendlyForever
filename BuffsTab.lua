-- The Buffs tab (#408): who gets each of your buffs, and where. A tab of the
-- options panel (Options.lua), shown in place of a message type's rows.
--
-- At the top, for every place: your buffs in the order they're offered,
-- each with its icon, Up and Down, and Never offer; then the self-buff,
-- water-breathing and group-version options. Below, a sub-tab for each place
-- (BuffRules.PLACES): Buff Back (strangers who buff you), Party, Raid and
-- PvP (battlegrounds and arenas), each with a row per buff for others: its
-- icon, its name, and a labelled "who gets it" button whose list ticks
-- Everyone, a role (not for strangers) or classes, or turns it Off; and, but
-- for strangers, its Always and Never names, opened under its row. Each
-- place's own options follow its rows.
--
-- Until the player chooses how to start (BuffRules.Pending), each sub-tab
-- shows the choice, "Keep my settings" or "Use the new defaults", and the
-- rules in force greyed: nothing changes that the player didn't press (the
-- owner, #408). Everything saves at once and refreshes the button.
local _, ns = ...

local BuffsTab = {}
ns.BuffsTab = BuffsTab

BuffsTab.PLACE_TEXT = { strangers = "Buff Back", party = "Party", raid = "Raid", pvp = "PvP" }
BuffsTab.PLACE_HELP = {
    strangers = "Buff Back: strangers who buff you. A stranger's role can't be seen, so it's by class. "
        .. "Buff back's line, timing and messages are on the Buff Back tab.",
    party = "Party: buff mode in a party, and on yourself when you're not in a group.",
    raid = "Raid: buff mode in a raid group.",
    pvp = "PvP: battlegrounds (before the gates open) and arenas. Every buff is off here unless you turn it on.",
}
BuffsTab.ROLE_TEXT = { tanks = "Tanks", healers = "Healers", damage = "Damage" }
BuffsTab.INTRO = "Who gets your buffs, and where. These rules are for buff back (strangers who buff you) "
    .. "and for buff mode (your party, raid, battleground or arena). Buff mode's key and when it turns on "
    .. "are on the Buff Back tab."
BuffsTab.CHOICE_TEXT = "Your buff rules haven't moved to the new places yet. Until you choose, buff mode "
    .. "and buff back work exactly as before."
BuffsTab.KEEP_NOTE = "copies your rules to Party and Raid; PvP starts off"
BuffsTab.NEW_NOTE = "recommended if you never changed them, or aren't sure"
-- The longest summary the who-gets button shows; a longer one is counted.
BuffsTab.SUMMARY_LETTERS = 24
BuffsTab.WHO_WIDTH = 200

local area           -- the tab's frame
local w              -- Options.widgets
local place = "party" -- the sub-tab shown
local namesKey       -- the buff whose Always and Never boxes are open, or nil
local listKey        -- the buff whose who-gets list is open, or nil

local function UI() return ns.Options.UI end

local function BuffBack() return UI().BuffBack() end

-- Your class's buffs in your order (read checked, #330).
local function OrderedClassBuffs()
    return ns.BuffData.InOrder(ns.BuffData.ClassBuffs(), ns.Config.Field("buffBack", "buffOrder"))
end

-- Self-buffs (#44) have no rule: only you get them. Nor has a buff offered
-- only when asked for (Water Walking, #350): whoever asks gets it.
local function HasWho(buff)
    return not buff.selfCast and not buff.requestOnly
end

local function NameText(buff)
    local name = ns.BuffData.SpellName(buff) or buff.key
    if buff.selfCast then name = name .. " " .. ns.Colours.Text("muted", "(you only)") end
    if buff.requestOnly then name = name .. " " .. ns.Colours.Text("muted", "(when asked)") end
    if not ns.BuffData.IsKnown(buff) then name = name .. " " .. ns.Colours.Text("muted", "(not known yet)") end
    return name
end

local function Count(names)
    local n = 0
    for _ in pairs(type(names) == "table" and names or {}) do n = n + 1 end
    return n
end

-- A rule as the who-gets button shows it: a short summary, and the whole
-- rule for its tooltip.
function BuffsTab.Summary(entry)
    local always = Count(entry.always)
    local tail = always > 0 and (", " .. always .. (always == 1 and " name" or " names")) or ""
    if entry.everyone == true then return "Everyone" .. tail, "Everyone" .. tail end
    local parts, roles, classes = {}, 0, 0
    for _, tick in ipairs(ns.BuffRules.ROLE_TICKS) do
        if entry[tick] == true then
            parts[#parts + 1] = BuffsTab.ROLE_TEXT[tick]
            roles = roles + 1
        end
    end
    for _, class in ipairs(ns.BuffRules.CLASSES) do
        if type(entry.classes) == "table" and entry.classes[class] == true then
            parts[#parts + 1] = UI().ClassText(class)
            classes = classes + 1
        end
    end
    local full = (#parts == 0 and "Off" or table.concat(parts, ", ")) .. tail
    if #full <= BuffsTab.SUMMARY_LETTERS then return full, full end
    local short = {}
    if roles > 0 then short[#short + 1] = roles .. (roles == 1 and " role" or " roles") end
    if classes > 0 then short[#short + 1] = classes .. (classes == 1 and " class" or " classes") end
    return table.concat(short, ", ") .. tail, full
end

-- What the who-gets button says before the choice: the 1.3.3 rule in force.
local function PendingSummary(buff)
    if place == "strangers" then return "Anyone who can use it" end
    return ns.BuffRules.RULE_TEXT[ns.BuffRules.Rule(buff)]
end

------------------------------------------------------------------------
-- The who-gets list: one, shown under the row it was opened from
------------------------------------------------------------------------

local function CloseList()
    listKey = nil
    if w.whoList then w.whoList:Hide() end
end

-- After a change from the list or a box: the button and the tab show it.
local function Changed(ok, why)
    if ok == false and why then ns.Print("who gets it not changed: " .. why .. ".") end
    ns.Options.Refresh()
end

function BuffsTab.SetTick(tick, on)
    if not listKey then return end
    Changed(ns.BuffRules.SetTick(listKey, place, tick, on))
end

function BuffsTab.SetClass(class, on)
    if not listKey then return end
    Changed(ns.BuffRules.SetPlaceClass(listKey, place, class, on))
end

function BuffsTab.SetOff()
    if not listKey then return end
    Changed(ns.BuffRules.SetOff(listKey, place))
end

-- Open (or close, when it's open for key) the list for key's row.
function BuffsTab.ToggleList(key)
    UI().ClearEditFocus()
    if listKey == key and w.whoList:IsShown() then return CloseList() end
    listKey = key
    w.whoList:Show()
    ns.Options.Refresh()
end

local function FillList(row)
    local list = w.whoList
    if not listKey or not row then return list:Hide() end
    local buff = ns.BuffData.ByKey(listKey)
    if not buff then return CloseList() end
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", row.who, "BOTTOMLEFT", 0, -2)
    local entry = ns.BuffRules.PlaceEntry(buff, place)
    list.everyone:SetChecked(entry.everyone == true)
    local strangers = place == "strangers"
    for _, tick in ipairs(ns.BuffRules.ROLE_TICKS) do
        list[tick]:SetShown(not strangers)
        list[tick]:SetChecked(entry[tick] == true)
    end
    for _, class in ipairs(ns.BuffRules.CLASSES) do
        list.classes[class]:SetChecked(type(entry.classes) == "table" and entry.classes[class] == true)
    end
end

local function CreateList()
    local ui = UI()
    local list = CreateFrame("Frame", nil, area)
    list:SetFrameStrata("DIALOG")
    list:SetSize(330, 150)
    list:Hide()
    -- Two layers of the palette's shade: dark enough to read over the rows.
    for _, layer in ipairs({ "BACKGROUND", "BORDER" }) do
        local shade = list:CreateTexture(nil, layer)
        shade:SetAllPoints(list)
        shade:SetColorTexture(ns.Colours.RGBA("shade"))
    end
    -- Behind the list: a click anywhere else closes it, as the dropdown's does (#274).
    local catcher = CreateFrame("Button", nil, list)
    catcher:SetAllPoints(UIParent)
    catcher:EnableMouse(true)
    catcher:SetScript("OnClick", CloseList)
    list.catcher = catcher
    list.everyone = ui.Checkbox(list, "Everyone", function(on) BuffsTab.SetTick("everyone", on) end)
    list.everyone:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -6)
    local prev
    for i, tick in ipairs(ns.BuffRules.ROLE_TICKS) do
        local cb = ui.Checkbox(list, BuffsTab.ROLE_TEXT[tick], function(on) BuffsTab.SetTick(tick, on) end)
        if i == 1 then
            cb:SetPoint("TOPLEFT", list.everyone, "BOTTOMLEFT", 0, -2)
        else
            cb:SetPoint("LEFT", prev.label, "RIGHT", 16, 0)
        end
        list[tick] = cb
        prev = cb
    end
    list.classesLabel = ui.Label(list, "Classes:", "GameFontNormalSmall")
    list.classesLabel:SetPoint("TOPLEFT", list.tanks, "BOTTOMLEFT", 4, -4)
    list.classes = {}
    local rowStart
    for i, class in ipairs(ns.BuffRules.CLASSES) do
        local cb = ui.Checkbox(list, ui.ClassText(class), function(on) BuffsTab.SetClass(class, on) end)
        if (i - 1) % 3 == 0 then
            cb:SetPoint("TOPLEFT", rowStart or list.classesLabel, "BOTTOMLEFT", rowStart and 0 or -4, -2)
            rowStart = cb
        else
            cb:SetPoint("LEFT", prev, "RIGHT", 90, 0)
        end
        list.classes[class] = cb
        prev = cb
    end
    list.off = ui.Button(list, "Off", 60, function() BuffsTab.SetOff() end)
    list.off:SetPoint("TOPLEFT", rowStart, "BOTTOMLEFT", 4, -4)
    ui.Tooltip(list.off, "Nobody gets it here: every tick cleared. Always names still get it.")
    list:SetScript("OnHide", function() listKey = nil end)
    w.whoList = list
end

------------------------------------------------------------------------
-- Always and Never names: one pair of boxes, under the row they're for
------------------------------------------------------------------------

function BuffsTab.ToggleNames(key)
    UI().ClearEditFocus()
    namesKey = namesKey ~= key and key or nil
    CloseList()
    ns.Options.Refresh()
end

-- A box lost focus: save it to the buff and place it was opened for, or say
-- why not and show what's kept. Unchanged text isn't saved.
function BuffsTab.SetNames(key, forPlace, list, text)
    if not key or not forPlace or text == ns.BuffRules.NamesText(key, list, forPlace) then
        return ns.Options.Refresh()
    end
    local ok, why = ns.BuffRules.SetNames(key, list, text, forPlace)
    if not ok then ns.Print((list == "always" and "Always" or "Never") .. " list not saved: " .. why .. ".") end
    ns.Options.Refresh()
end

------------------------------------------------------------------------
-- Paladins: the Blessings given in this raid (Raid sub-tab; not saved)
------------------------------------------------------------------------

function BuffsTab.SetRaidBlessing()
    BuffBack() -- the button then refreshes from it: never a damaged section (#330)
    local keys = {}
    for _, cb in ipairs(w.who.raidBlessings) do
        if cb:IsShown() and cb.key and cb:GetChecked() then keys[#keys + 1] = cb.key end
    end
    local ok, why = ns.BuffRules.SetRaidBlessings(keys)
    if not ok then ns.Print("Blessings for this raid not changed: " .. why .. ".") end
    ns.Options.Refresh()
end

local function FillRaidBlessings(shown, last)
    local who = w.who
    local mine = shown and ns.BuffRules.MyBlessings() or {}
    local inRaid = ns.Util.ReadGameValues(IsInRaid) == true
    who.raidHeader:SetShown(#mine > 0)
    for i, cb in ipairs(who.raidBlessings) do
        local buff = mine[i]
        cb:SetShown(buff ~= nil)
        cb.key = buff and buff.key
        if buff then
            cb.label:SetText(ns.BuffData.SpellName(buff) or buff.key)
            cb:SetChecked(ns.BuffRules.CoversInRaid(buff))
            cb:SetEnabled(inRaid)
        end
    end
    if #mine == 0 then return last end
    who.raidHeader:ClearAllPoints()
    who.raidHeader:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, -12)
    who.raidHeader:SetText("Blessings I give in this raid:  "
        .. ns.Colours.Text("muted", inRaid and "(until you leave it)" or "(join a raid to choose)"))
    return who.raidBlessings[1]
end

------------------------------------------------------------------------
-- Making and filling the tab
------------------------------------------------------------------------

-- The most rows any class needs: its buffs, and those with a rule.
local function MostRows()
    local most, mostWho = 0, 0
    for _, list in pairs(ns.BuffData.CLASSES) do
        local who = 0
        for _, buff in ipairs(list) do
            if HasWho(buff) then who = who + 1 end
        end
        most, mostWho = math.max(most, #list), math.max(mostWho, who)
    end
    return most, mostWho
end

local function Icon(parent)
    local icon = parent:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    return ns.Options.Noted(icon, parent)
end

local function Check(field, text, tooltip, after)
    local cb = UI().Checkbox(area, text, function(on)
        BuffBack()[field] = on
        if after then after() end
        ns.BuffButton.Refresh()
    end)
    if tooltip then UI().Tooltip(cb, tooltip) end
    return cb
end

-- Makes the tab's rows in content, below the tabs (tabsBottom).
function BuffsTab.Create(content, tabsBottom)
    local ui = UI()
    w = ns.Options.widgets
    -- The panel's own scrolling content: the rows are its children, noted
    -- (Options.Collect) so the tab shows them.
    area = content

    w.buffsHeader = ui.Label(area, "Buffs", "GameFontNormal")
    w.buffsHeader:SetPoint("TOPLEFT", tabsBottom, "BOTTOMLEFT", 0, -16)
    w.buffsHelp = ui.Label(area, BuffsTab.INTRO, "GameFontHighlightSmall")
    w.buffsHelp:SetPoint("TOPLEFT", w.buffsHeader, "BOTTOMLEFT", 0, -4)
    w.buffsHelp:SetPoint("RIGHT", area, "RIGHT", -24, 0)
    w.buffsHelp:SetWordWrap(true)

    -- The buff order, one row per buff of your class (the most any class has).
    w.buffOrderHeader = ui.Label(area, "", "GameFontNormalSmall")
    w.buffOrderHeader:SetPoint("TOPLEFT", w.buffsHelp, "BOTTOMLEFT", 0, -12)
    local most, mostWho = MostRows()
    w.buffRows = {}
    local above = w.buffOrderHeader
    for i = 1, most do
        local row = {}
        row.icon = Icon(area)
        row.icon:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -8)
        row.name = ui.Label(area, "", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetWidth(220)
        row.up = ui.Button(area, "Up", 44, function() if row.key then ns.Options.MoveBuff(row.key, -1) end end)
        row.up:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
        ui.Tooltip(row.up, "Offer this buff before the one above it.")
        row.down = ui.Button(area, "Down", 54, function() if row.key then ns.Options.MoveBuff(row.key, 1) end end)
        row.down:SetPoint("LEFT", row.up, "RIGHT", 4, 0)
        ui.Tooltip(row.down, "Offer this buff after the one below it.")
        row.never = ui.Checkbox(area, "Never offer", function(on)
            if row.key then ns.Options.SetNeverOffer(row.key, on) end
        end)
        row.never:SetPoint("LEFT", row.down, "RIGHT", 10, 0)
        ui.Tooltip(row.never, "Never offered, anywhere: not to strangers, not in buff mode. "
            .. "A player who asks for it in chat still gets it.")
        w.buffRows[i] = row
        above = row.icon
    end

    w.selfBuffs = Check("selfBuffs", "Offer my self-buffs in buff mode, after everyone else",
        ns.Options.SELF_BUFFS_TOOLTIP)
    w.breathNearWater = Check("breathNearWater", "Water breathing: only near water", ns.Options.BREATH_TOOLTIP)
    w.breathNearWater:SetPoint("TOPLEFT", w.selfBuffs, "BOTTOMLEFT", 0, -2)
    w.groupVersions = Check("groupVersions", "Use group versions (Arcane Brilliance, the Prayers, Gift of the Wild)",
        ns.Options.GROUP_VERSIONS_TOOLTIP)
    w.groupVersions:SetPoint("TOPLEFT", w.breathNearWater, "BOTTOMLEFT", 0, -2)
    local enough = ui.Stepper(area, "...when at least this many are missing the buff:", "groupEnough", BuffBack)
    enough.label:SetPoint("TOPLEFT", w.groupVersions, "BOTTOMLEFT", 4, -8)
    w.steppers.groupEnough = enough

    -- The places' sub-tabs.
    w.placeTabs = {}
    local prev
    for i, p in ipairs(ns.BuffRules.PLACES) do
        local tab = ui.Button(area, BuffsTab.PLACE_TEXT[p], 90, function() BuffsTab.SelectPlace(p) end)
        if i == 1 then
            tab:SetPoint("TOPLEFT", enough.label, "BOTTOMLEFT", 0, -18)
        else
            tab:SetPoint("LEFT", prev, "RIGHT", 6, 0)
        end
        w.placeTabs[p] = tab
        prev = tab
    end
    w.placeHelp = ui.Label(area, "", "GameFontHighlightSmall")
    w.placeHelp:SetPoint("TOPLEFT", w.placeTabs[ns.BuffRules.PLACES[1]], "BOTTOMLEFT", 0, -8)
    w.placeHelp:SetPoint("RIGHT", area, "RIGHT", -24, 0)
    w.placeHelp:SetWordWrap(true)

    -- The choice, before it's made.
    w.choice = {}
    w.choice.text = ui.Label(area, ns.Colours.Text("warn", BuffsTab.CHOICE_TEXT), "GameFontHighlightSmall")
    w.choice.text:SetPoint("RIGHT", area, "RIGHT", -24, 0)
    w.choice.text:SetWordWrap(true)
    w.choice.keep = ui.Button(area, "Keep my settings", 160, function() BuffsTab.Choose("kept") end)
    w.choice.keep:SetPoint("TOPLEFT", w.choice.text, "BOTTOMLEFT", 0, -6)
    w.choice.keepNote = ui.Label(area, BuffsTab.KEEP_NOTE, "GameFontHighlightSmall")
    w.choice.keepNote:SetPoint("LEFT", w.choice.keep, "RIGHT", 8, 0)
    w.choice.new = ui.Button(area, "Use the new defaults", 160, function() BuffsTab.Choose("new") end)
    w.choice.new:SetPoint("TOPLEFT", w.choice.keep, "BOTTOMLEFT", 0, -4)
    w.choice.newNote = ui.Label(area, BuffsTab.NEW_NOTE, "GameFontHighlightSmall")
    w.choice.newNote:SetPoint("LEFT", w.choice.new, "RIGHT", 8, 0)

    -- A row per buff with a rule (anchored in Fill).
    w.whoRows = {}
    for i = 1, mostWho do
        local row = {}
        row.icon = Icon(area)
        row.name = ui.Label(area, "", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetWidth(170)
        row.label = ui.Label(area, "Who gets it:", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT", row.name, "RIGHT", 6, 0)
        row.who = ui.Button(area, "", BuffsTab.WHO_WIDTH, function()
            if row.key then BuffsTab.ToggleList(row.key) end
        end)
        row.who:SetPoint("LEFT", row.label, "RIGHT", 6, 0)
        row.names = ui.Button(area, "", 90, function() if row.key then BuffsTab.ToggleNames(row.key) end end)
        row.names:SetPoint("LEFT", row.who, "RIGHT", 6, 0)
        ui.Tooltip(row.names, "Players named here: Always get it, whatever the rule; Never don't.")
        w.whoRows[i] = row
    end
    CreateList()

    -- The Always and Never boxes, under their row (anchored in Fill).
    local who = { raidBlessings = {} }
    w.who = who
    local function NamesBox(list, labelText)
        local label = ui.Label(area, labelText, "GameFontHighlightSmall")
        label:SetWidth(60)
        local box = ui.TextBox(area, 380, ns.BuffRules.MAX_LIST_LETTERS)
        box:SetPoint("LEFT", label, "RIGHT", 6, 0)
        box:SetScript("OnEditFocusGained", function(self) self.buffKey, self.place = namesKey, place end)
        box:SetScript("OnEditFocusLost", function(self)
            local key, forPlace = self.buffKey, self.place
            self.buffKey, self.place = nil, nil
            BuffsTab.SetNames(key, forPlace, list, self:GetText())
        end)
        return label, box
    end
    who.alwaysLabel, who.always = NamesBox("always", "Always:")
    who.neverLabel, who.never = NamesBox("never", "Never:")
    who.neverLabel:SetPoint("TOPLEFT", who.alwaysLabel, "BOTTOMLEFT", 0, -12)

    -- Each place's own options.
    w.openBuffBack = ui.Button(area, "Open the Buff Back tab", 170, function() ns.Options.SelectType("buffBack") end)
    w.soloOwnBuffs = Check("soloOwnBuffs", "Offer my own buffs when I'm not in a group",
        ns.Options.SOLO_OWN_BUFFS_TOOLTIP)
    w.raidSplit = Check("raidSplit", "Share buffs with other copies in raids", ns.Options.RAID_SPLIT_TOOLTIP)
    who.raidHeader = ui.Label(area, "", "GameFontNormalSmall")
    local mostBlessings = 0
    for _, list in pairs(ns.BuffData.CLASSES) do
        local n = 0
        for _, buff in ipairs(list) do if buff.family == "blessing" then n = n + 1 end end
        mostBlessings = math.max(mostBlessings, n)
    end
    for i = 1, mostBlessings do
        local cb = ui.Checkbox(area, "", function() BuffsTab.SetRaidBlessing() end)
        if i == 1 then
            cb:SetPoint("TOPLEFT", who.raidHeader, "BOTTOMLEFT", -4, -2)
        else
            cb:SetPoint("LEFT", who.raidBlessings[i - 1].label, "RIGHT", 12, 0)
        end
        who.raidBlessings[i] = cb
    end
    w.bgPrepBuff = Check("bgPrepBuff", "Buff in a battleground's preparation phase", nil,
        function() ns.Battleground.Update() end)
end

-- Whether frame is one of the tab's rows, or in one (a checkbox's label).
function BuffsTab.Owns(frame)
    for _, row in ipairs(ns.Options.BuffsRows()) do
        local f = frame
        while f do
            if f == row then return true end
            f = f.GetParent and f:GetParent() or nil
        end
    end
    return false
end

-- Another tab is shown: the list closes.
function BuffsTab.Close()
    if w and w.whoList then CloseList() end
end
function BuffsTab.Place() return place end

-- Show place's sub-tab.
function BuffsTab.SelectPlace(p)
    if not ns.BuffRules.PLACE_FIELD[p] then return end
    UI().ClearEditFocus()
    place, namesKey = p, nil
    CloseList()
    ns.Options.Refresh()
end

-- Make the choice (#408) from the tab's buttons.
function BuffsTab.Choose(choice)
    UI().ClearEditFocus()
    CloseList()
    local ok, why = ns.BuffRules.Choose(choice)
    if not ok then ns.Print("buff rules not changed: " .. why .. ".") end
    ns.Options.Refresh()
end

local function FillOrder(buffs)
    w.buffOrderHeader:SetText(#buffs == 0 and "Your class has no buffs to offer."
        or "Your buffs, in the order they're offered (every place):")
    for i, row in ipairs(w.buffRows) do
        local buff = buffs[i]
        for _, part in ipairs({ row.icon, row.name, row.up, row.down, row.never }) do part:SetShown(buff ~= nil) end
        row.key = buff and buff.key
        if buff then
            row.icon:SetTexture(ns.BuffData.Icon(buff))
            row.name:SetText(i .. ". " .. NameText(buff))
            row.up:SetEnabled(i > 1)
            row.down:SetEnabled(i < #buffs)
            row.never:SetChecked(ns.BuffData.NeverOffered(buff))
        end
    end
    local last = buffs[1] and w.buffRows[#buffs].icon or w.buffOrderHeader
    w.selfBuffs:ClearAllPoints()
    w.selfBuffs:SetPoint("TOPLEFT", last, "BOTTOMLEFT", -4, -10)
    local b = ns.db.buffBack
    w.selfBuffs:SetChecked(b.selfBuffs == true)
    w.breathNearWater:SetChecked(b.breathNearWater == true)
    w.groupVersions:SetChecked(b.groupVersions == true)
    UI().FillBox(w.steppers.groupEnough.box, tostring(b.groupEnough))
end

-- The rows of the place shown; returns what the place's options anchor to.
local function FillRows(buffs, pending, last)
    local who, named, listRow = w.who, ns.BuffRules.NAMED_PLACES[place], nil
    local rules = {}
    for _, buff in ipairs(buffs) do
        if HasWho(buff) then rules[#rules + 1] = buff end
    end
    if namesKey and (pending or not named) then namesKey = nil end
    local namesShown = false
    for i, row in ipairs(w.whoRows) do
        local buff = rules[i]
        for _, part in ipairs({ row.icon, row.name, row.label, row.who }) do part:SetShown(buff ~= nil) end
        row.names:SetShown(buff ~= nil and named == true)
        row.key = buff and buff.key
        if buff then
            row.icon:ClearAllPoints()
            row.icon:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, i == 1 and -10 or -8)
            row.icon:SetTexture(ns.BuffData.Icon(buff))
            row.name:SetText(NameText(buff))
            local short, full
            if pending then
                short = PendingSummary(buff)
                full = short
            else
                short, full = BuffsTab.Summary(ns.BuffRules.PlaceEntry(buff, place))
            end
            row.who:SetText(short)
            UI().Tooltip(row.who, pending and "Choose how to start, above, to change who gets it."
                or ("Who gets " .. (ns.BuffData.SpellName(buff) or buff.key) .. " here: " .. full
                .. ". Click to change it."))
            row.who:SetEnabled(not pending)
            row.names:SetEnabled(not pending)
            if named then
                local entry = ns.BuffRules.PlaceEntry(buff, place)
                row.names:SetText("Names (" .. (Count(entry.always) + Count(entry.never)) .. ")")
            end
            if buff.key == listKey then listRow = row end
            last = row.icon
            if buff.key == namesKey and named then
                namesShown = true
                who.alwaysLabel:ClearAllPoints()
                who.alwaysLabel:SetPoint("TOPLEFT", row.icon, "BOTTOMLEFT", 24, -10)
                UI().FillBox(who.always, ns.BuffRules.NamesText(buff.key, "always", place))
                UI().FillBox(who.never, ns.BuffRules.NamesText(buff.key, "never", place))
                last = who.neverLabel
            end
        end
    end
    for _, part in ipairs({ who.alwaysLabel, who.always, who.neverLabel, who.never }) do part:SetShown(namesShown) end
    if not namesShown then namesKey = nil end
    if pending or not listRow then CloseList() else FillList(listRow) end
    return last, #rules
end

-- A place's own options, after its rows.
local function FillOptions(last)
    local b = ns.db.buffBack
    local function Below(frame, shown, x, y)
        frame:SetShown(shown)
        if not shown then return end
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", last, "BOTTOMLEFT", x or 0, y or -10)
        last = frame
    end
    Below(w.openBuffBack, place == "strangers", 0, -12)
    Below(w.soloOwnBuffs, place == "party", -4)
    if place == "party" then w.soloOwnBuffs:SetChecked(b.soloOwnBuffs == true) end
    Below(w.raidSplit, place == "raid", -4)
    if place == "raid" then w.raidSplit:SetChecked(ns.RaidSplit.Enabled()) end
    last = FillRaidBlessings(place == "raid", last)
    Below(w.bgPrepBuff, place == "pvp", -4)
    if place == "pvp" then w.bgPrepBuff:SetChecked(b.bgPrepBuff == true) end
    return last
end

function BuffsTab.Fill()
    if not area then return end
    local buffs = OrderedClassBuffs()
    FillOrder(buffs)
    local pending = ns.BuffRules.Pending()
    for p, tab in pairs(w.placeTabs) do tab:SetEnabled(p ~= place) end
    w.placeHelp:SetText(BuffsTab.PLACE_HELP[place])
    local last = w.placeHelp
    for _, part in pairs(w.choice) do part:SetShown(pending) end
    if pending then
        w.choice.text:ClearAllPoints()
        w.choice.text:SetPoint("TOPLEFT", w.placeHelp, "BOTTOMLEFT", 0, -10)
        last = w.choice.new
    end
    local rules
    last, rules = FillRows(buffs, pending, last)
    if rules == 0 and #buffs > 0 then
        w.placeHelp:SetText(BuffsTab.PLACE_HELP[place] .. "  "
            .. ns.Colours.Text("muted", "(your class has no buffs for others)"))
    end
    FillOptions(last)
end
