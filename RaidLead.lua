-- Raid buff assignments (#497, experimental: tested in specs and the UI
-- simulator only, until a player reports back). The raid leader and raid
-- assistants can say who gives which buff to which groups ("Fortitude: Ann
-- Vale for groups 1-4, Bob Lake for 5-8"). That overrides the automatic
-- raid split (RaidSplit.lua) for those buffs only; the rest stays
-- automatic. RaidSplit applies it; this file keeps it, shares it and shows
-- the window.
--
-- The safety rule (owner, 18 Nov): another player can only narrow what
-- your addon offers, never make it cast. Every cast is still your own press
-- on the secure button. An assignment only decides which copy offers a
-- buff to which groups, and one that can't be met (the player is offline,
-- out of the raid, doesn't run the addon or doesn't give that buff) falls
-- back to the automatic split for that buff.
--
-- The assignments are one versioned section (Versioned.lua) on the RAID
-- route. Each item is a short token: a buff key the split shares, the
-- groups as two hex digits (bit 1 is group 1), and an eight-hex-digit hash
-- of the player's full name (names are too long for an item). Never text
-- anyone says, and never code.
--
-- Who may set them is never read from a message: the sender's rank is
-- looked up in the raid roster (GetRaidRosterInfo) for every part as it
-- arrives: 2 is the leader, 1 an assistant. An unreadable roster, rank or
-- raid answer means nobody may (fail closed).
--
-- They're kept for this session only, for the raid you're in. Leaving the
-- raid forgets them; a new leader clears them. A copy that joins (or
-- reloads) checks in (RCHECK) with the version it keeps, and a leader's or
-- assistant's copy that keeps a newer one sends it after a random wait,
-- unless another sends it first, and at most once per SEND_GAP.
local _, ns = ...
local Util = ns.Util
local Comm = ns.Comm
local Versioned = ns.Versioned
local Read = Util.ReadGameValues

local RaidLead = {}
ns.RaidLead = RaidLead

RaidLead.GROUPS = 8
RaidLead.MAX_ITEMS = 30     -- (buff, player) pairs: every one fits in Versioned's six parts
RaidLead.ITEM_BYTES = 20    -- a key of at most 10 letters, 2 hex digits of groups, 8 of hash
RaidLead.CHECKIN_WAIT_MIN = 2  -- seconds after joining a raid before checking in, at random
RaidLead.CHECKIN_WAIT_MAX = 8
RaidLead.CHECKIN_GAP = 60      -- the shortest time between two of our check-ins
RaidLead.SEND_WAIT_MIN = 2     -- seconds a leader's copy waits, at random, before catching others up
RaidLead.SEND_WAIT_MAX = 10
RaidLead.SEND_GAP = 60         -- the shortest time between two catch-up sends
RaidLead.EDIT_WAIT = 2         -- seconds an edit waits before going out, so quick edits go as one

-- Overridable so tests can make the waits deterministic: () -> [0, 1).
RaidLead.random = math.random

local RAID_UNITS = {}
for i = 1, 40 do RAID_UNITS[i] = "raid" .. i end

------------------------------------------------------------------------
-- Items
------------------------------------------------------------------------

-- [key] = buff for every buff the raid split shares, of any class: not
-- cast on yourself, not offered only when asked for (RaidSplit's Shared).
-- (After an update and a /reload without a restart, BuffData may be
-- missing: the addon then stays inert, Core.lua, and there are none.)
local SHARED, ORDER = {}, {}
local CLASSES = ns.BuffData and ns.BuffData.CLASSES or {}
for _, class in ipairs({ "PRIEST", "MAGE", "DRUID", "PALADIN", "SHAMAN", "WARLOCK", "HUNTER", "WARRIOR", "ROGUE" }) do
    for _, buff in ipairs(CLASSES[class] or {}) do
        if not buff.selfCast and not buff.requestOnly and #buff.key <= 10 and buff.key:find("^[a-z]+$")
            and not SHARED[buff.key] then
            SHARED[buff.key] = buff
            ORDER[#ORDER + 1] = buff
        end
    end
end
RaidLead.SHARED = SHARED

-- A full name's hash: eight lower-case hex digits (djb2 over its bytes,
-- kept below 2^32; written in two halves, since the game's string.format
-- may read %x through a 32-bit integer).
function RaidLead.Hash(name)
    local h = 5381
    for i = 1, #name do h = (h * 33 + name:byte(i)) % 4294967296 end
    return string.format("%04x%04x", math.floor(h / 65536), h % 65536)
end

-- An item's parts: its buff key, its groups ({ [g] = true }, at least one)
-- and its player's hash; nil when it isn't an item.
local function Parse(text)
    if type(text) ~= "string" then return nil end
    -- (Shorter or longer items leave a key that isn't a shared buff's.)
    local key, mask, hash = text:sub(1, -11), text:sub(-10, -9), text:sub(-8)
    if not SHARED[key] or not (mask .. hash):find("^[0-9a-f]+$") then return nil end
    local bits = tonumber(mask, 16)
    if bits < 1 then return nil end
    local groups = {}
    for g = 1, RaidLead.GROUPS do
        if math.floor(bits / 2 ^ (g - 1)) % 2 == 1 then groups[g] = true end
    end
    return key, groups, hash
end
RaidLead.Parse = Parse

-- The item for a buff key, groups ({ [g] = true }) and a full name.
function RaidLead.Item(key, groups, name)
    local bits = 0
    for g = 1, RaidLead.GROUPS do
        if groups[g] then bits = bits + 2 ^ (g - 1) end
    end
    return key .. string.format("%02x", bits) .. RaidLead.Hash(name)
end

-- Each (buff, player) pair at most once.
local function Together(items)
    local seen = {}
    for _, item in ipairs(items) do
        local pair = item:sub(1, -11) .. item:sub(-8)
        if seen[pair] then return false end
        seen[pair] = true
    end
    return true
end

------------------------------------------------------------------------
-- The raid, who may assign, and the clock
------------------------------------------------------------------------

local function InRaid()
    return ns.GroupBuffs.RaidAnswer()
end

-- The raid as its roster says now: [full name] = { unit, rank (2 the
-- leader, 1 an assistant, anything else neither), class }, and the
-- leader's full name: nil when it can't be read, or no one or more than
-- one slot reads as leading.
local function Roster()
    local out, leader, leaders = {}, nil, 0
    for i, unit in ipairs(RAID_UNITS) do
        -- An empty or unreadable slot has no name. (A name in two slots would
        -- count twice: two leaders, so nobody may assign.)
        local name = Util.UnitFullName(unit)
        if name then
            local _, rank = Read(GetRaidRosterInfo, i)
            local _, class = Read(UnitClass, unit)
            out[name] = { unit = unit, rank = rank, class = type(class) == "string" and class or nil }
            if rank == 2 then
                leaders = leaders + 1
                leader = name
            end
        end
    end
    if leaders ~= 1 then leader = nil end
    return out, leader
end
RaidLead.Roster = Roster

-- Whether this player may set the assignments now: in your raid, its
-- roster readable enough to name one leader, and theirs the leader's or an
-- assistant's rank. False whenever it can't be told.
function RaidLead.MayAssign(name)
    if type(name) ~= "string" or InRaid() ~= true then return false end
    local roster, leader = Roster()
    local member = roster[name]
    return leader ~= nil and member ~= nil and (member.rank == 1 or member.rank == 2)
end

-- Seconds on the server's clock (or yours), as a whole number, or 0.
local function Clock()
    local function Plain(now)
        return type(now) == "number" and now == now and now >= 1 and now <= Versioned.MAX_VERSION
    end
    local now = Read(GetServerTime)
    if not Plain(now) then now = Read(time) end
    if not Plain(now) then return 0 end
    return math.floor(now)
end

------------------------------------------------------------------------
-- The assignments kept
------------------------------------------------------------------------

-- { version, items, leader = the raid's leader when they were set }.
local kept = { version = 0, items = {} }
local pending -- a send waiting: { version, encoded }
local lastSent

local function Changed()
    if ns.RaidSplit.Changed then ns.RaidSplit.Changed() end
end

-- Forget them as you leave the raid, and clear them when its leader
-- changes. Run before every use, so neither waits for a roster update. Only
-- on positive evidence: a believable "not in a raid", or a leader read now
-- and when they were set, and different. Clearing keeps a higher version,
-- so the old list, sent again, is old.
local function Check()
    local inRaid = InRaid()
    if inRaid == false then
        if kept.version > 0 then
            kept, pending = { version = 0, items = {} }, nil
            Changed()
            ns.Diag.Log("raidlead", "left the raid: assignments forgotten")
        end
        return
    end
    if inRaid ~= true or not kept.leader then return end
    local _, leader = Roster()
    if leader and leader ~= kept.leader then
        kept = { version = math.min(kept.version + 1, Versioned.MAX_VERSION), items = {}, leader = leader }
        pending = nil
        Changed()
        ns.Diag.Log("raidlead", "a new raid leader: assignments cleared")
    end
end

-- The assignments in force: a list of { key, groups = { [g] = true }, hash }.
-- Empty out of a raid, or while the game won't say you're in one.
function RaidLead.Assignments()
    Check()
    local out = {}
    if InRaid() ~= true then return out end
    for _, item in ipairs(kept.items) do
        local key, groups, hash = Parse(item)
        if key then out[#out + 1] = { key = key, groups = groups, hash = hash } end
    end
    return out
end

function RaidLead.Version()
    return kept.version
end

-- A copy of the items kept ({} when none).
function RaidLead.Items()
    local out = {}
    for i, item in ipairs(kept.items) do out[i] = item end
    return out
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------

local section -- the Versioned section, below

local function Wait(min, max)
    return min + RaidLead.random() * (max - min)
end

local function SendNow(p)
    if pending ~= p then return end -- cancelled, or replaced
    pending = nil
    -- You may have lost the rank, or left, while it waited.
    local me = Util.UnitFullName("player")
    if not me or not RaidLead.MayAssign(me) then return end
    lastSent = GetTime()
    local ok, why = section.Send()
    ns.Diag.Log("raidlead", "sent the assignments: %s", ok and "queued" or why)
end

-- Send what you keep to the raid after wait seconds, unless a send is
-- waiting; a catch-up send (not an edit) waits out SEND_GAP since the last.
local function ScheduleSend(wait, edit)
    if pending or kept.version < 1 then return end
    local now = GetTime()
    if not edit and lastSent and now >= lastSent then wait = math.max(wait, lastSent + RaidLead.SEND_GAP - now) end
    local p = { version = kept.version, encoded = Versioned.Encode(kept.items) }
    pending = p
    C_Timer.After(wait, ns.Diag.Wrap(function() SendNow(p) end))
end

-- Set the raid's assignments (the window): items is a list of items.
-- Returns true, or false and why.
function RaidLead.Set(items)
    if not section then return false, "the addon isn't fully loaded" end
    local me = Util.UnitFullName("player")
    if not me or not RaidLead.MayAssign(me) then return false, "only the raid leader or an assistant can" end
    Check()
    if type(items) ~= "table" then return false, "not a list" end
    local list = {}
    for i, item in ipairs(items) do list[i] = item end
    if not Versioned.ValidList(section, list) then return false, "not assignments the addon can share" end
    table.sort(list)
    if Versioned.Encode(list) == Versioned.Encode(kept.items) then return true end
    local version = math.max(Clock(), kept.version + 1)
    if version > Versioned.MAX_VERSION then return false, "can't be changed any more" end
    local _, leader = Roster()
    kept = { version = version, items = list, leader = leader }
    pending = nil
    ScheduleSend(RaidLead.EDIT_WAIT, true)
    Changed()
    ns.Diag.Log("raidlead", "set the assignments, version %s", version)
    return true
end

------------------------------------------------------------------------
-- Check-ins
------------------------------------------------------------------------

local checkPending, lastCheck
local joined = false -- whether we've checked in to the raid we're in

function RaidLead.CheckIn()
    if InRaid() ~= true then return false end
    lastCheck = GetTime()
    return Comm.Send("RCHECK", { string.format("%.0f", kept.version) }, "RAID")
end

local function ScheduleCheckIn(wait)
    if checkPending then return end
    local now = GetTime()
    if lastCheck and now >= lastCheck then wait = math.max(wait, lastCheck + RaidLead.CHECKIN_GAP - now) end
    checkPending = true
    C_Timer.After(wait, ns.Diag.Wrap(function()
        checkPending = nil
        RaidLead.CheckIn()
    end))
end

-- RCHECK from a raid member: the version they keep. It can only ask a
-- leader's or assistant's copy to send what it keeps (SendNow checks), or
-- prompt our own check-in when theirs is newer and they may send it.
local function OnCheckIn(sender, fields)
    if InRaid() ~= true then return end
    Check()
    local roster = Roster()
    if not roster[sender] then
        ns.Diag.Count("raidLeadNotMember")
        return ns.Diag.Log("raidlead", "a check-in from %s, who isn't in the raid", sender)
    end
    local theirs = tonumber(fields[1])
    if kept.version > theirs then ScheduleSend(Wait(RaidLead.SEND_WAIT_MIN, RaidLead.SEND_WAIT_MAX)) end
    if theirs > kept.version and RaidLead.MayAssign(sender) then
        ScheduleCheckIn(Wait(RaidLead.SEND_WAIT_MIN, RaidLead.SEND_WAIT_MAX))
    end
end

-- After each roster update and login (Core.lua): forget or clear (Check),
-- and check in once to a raid we've joined.
function RaidLead.OnRosterUpdate()
    Check()
    local inRaid = InRaid()
    if inRaid == false then joined = false end
    if inRaid == true and not joined and section then
        joined = true
        ScheduleCheckIn(Wait(RaidLead.CHECKIN_WAIT_MIN, RaidLead.CHECKIN_WAIT_MAX))
    end
    RaidLead.Refresh()
end

-- After an update and a /reload without a restart, Comm or Versioned may be
-- missing: the addon then stays inert (Core.lua), so nothing is registered.
if Comm and Versioned then
    section = Versioned.Define({
        type = "RASSIGN", route = "RAID",
        item = function(text) return Parse(text) ~= nil end,
        itemBytes = RaidLead.ITEM_BYTES, whole = Together, maxItems = RaidLead.MAX_ITEMS,
        authority = RaidLead.MayAssign,
        -- (Out of a raid, or while that can't be told, nobody has the
        -- authority, which Versioned asks first: nothing is taken.)
        get = function()
            Check()
            return kept
        end,
        set = function(version, items)
            local _, leader = Roster()
            kept = { version = version, items = items, leader = leader }
            Changed()
            RaidLead.Refresh()
        end,
        heard = function(version, encoded)
            if pending and not Versioned.Newer(pending.version, pending.encoded, version, encoded) then
                pending = nil
                ns.Diag.Log("raidlead", "leaving the assignments to another copy")
            end
        end,
    })
    Comm.RegisterType("RCHECK", {
        fields = { Versioned.StampField },
        routes = { RAID = true },
        handler = OnCheckIn,
    })
end
RaidLead.section = section

------------------------------------------------------------------------
-- What the window reads and writes
------------------------------------------------------------------------

-- "1-4", "1, 3 and 5-8", or nil for every group.
local function GroupsText(groups)
    local runs, g = {}, 1
    while g <= RaidLead.GROUPS do
        if groups[g] then
            local from = g
            while groups[g + 1] do g = g + 1 end
            runs[#runs + 1] = from == g and tostring(from) or (from .. "-" .. g)
        end
        g = g + 1
    end
    if #runs == 1 and runs[1] == "1-" .. RaidLead.GROUPS then return nil end
    return table.concat(runs, " ")
end

-- The assignments as the window shows them: [key] = "Ann Vale 1-4, Bob Lake",
-- each player named from the raid's roster. One who isn't in it now is
-- left out (they can't be met: a save drops them).
function RaidLead.Texts()
    local names = {}
    for name in pairs(Roster()) do names[RaidLead.Hash(name)] = name end
    local lists = {}
    for _, a in ipairs(RaidLead.Assignments()) do
        local name = names[a.hash]
        if name then
            local groups = GroupsText(a.groups)
            lists[a.key] = lists[a.key] or {}
            local list = lists[a.key]
            list[#list + 1] = Util.DisplayName(name) .. (groups and (" " .. groups) or "")
        end
    end
    local out = {}
    for key, list in pairs(lists) do
        table.sort(list)
        out[key] = table.concat(list, ", ")
    end
    return out
end

-- The groups in words such as {"1-4"} or {"1", "3"}, or nil if any isn't one.
local function ParseGroups(words)
    local groups, any = {}, false
    for _, word in ipairs(words) do
        local from, to = word:match("^(%d)%-(%d)$")
        if not from then
            from = word:match("^(%d)$")
            to = from
        end
        from, to = tonumber(from), tonumber(to)
        if not from or from < 1 or to > RaidLead.GROUPS or from > to then return nil end
        for g = from, to do groups[g] = true end
        any = true
    end
    if not any then
        for g = 1, RaidLead.GROUPS do groups[g] = true end
    end
    return groups
end

-- The raid member a typed name means: their whole name ("Ann Vale" or
-- "Ann-Vale"), or their first name when only one member has it.
local function FindMember(roster, typed)
    local want = typed:lower():gsub("%-", " ")
    local byFirst
    for name in pairs(roster) do
        if Util.DisplayName(name):lower() == want then return name end
        if Util.FirstName(name):lower() == want then
            if byFirst then return nil, "more than one member is called " .. typed end
            byFirst = name
        end
    end
    if byFirst then return byFirst end
    return nil, "nobody called " .. typed .. " is in the raid"
end

-- The items one buff's line of the window means ("Ann Vale 1-4, Bob 5 6"),
-- or nil and why. Typed text: untrusted, and only ever echoed stripped.
function RaidLead.ParseLine(key, text, roster)
    local buff = SHARED[key]
    if not buff then return nil, "not a buff the raid shares" end
    local items = {}
    if type(text) ~= "string" then return items end
    for entry in (text .. ","):gmatch("([^,;]*)[,;]") do
        local words = {}
        for word in entry:gmatch("%S+") do words[#words + 1] = word end
        if #words > 0 then
            local first = #words + 1
            while first > 1 and words[first - 1]:find("^%d") do first = first - 1 end
            local nameWords, groupWords = {}, {}
            for i, word in ipairs(words) do
                if i < first then nameWords[#nameWords + 1] = word else groupWords[#groupWords + 1] = word end
            end
            -- No name ("1-4") finds nobody.
            local typed = Util.StripChat(table.concat(nameWords, " "))
            local name, why = FindMember(roster, typed)
            if not name then return nil, why end
            local groups = ParseGroups(groupWords)
            if not groups then return nil, "groups are 1 to 8, such as 1-4 or 5 6" end
            local class = roster[name].class
            local gives = class == nil
            for _, b in ipairs(class and ns.BuffData.CLASSES[class] or {}) do
                if b.key == key then gives = true end
            end
            if not gives then
                return nil, Util.DisplayName(name) .. " can't give " .. (ns.BuffData.SpellName(buff) or key)
            end
            items[#items + 1] = RaidLead.Item(key, groups, name)
        end
    end
    return items
end

------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------

RaidLead.WINDOW = "FriendlyForeverRaidWindow"
local ROW_HEIGHT = 30
local frame

local function SetStatus(text, colour)
    frame.status:SetText(colour and ns.Colours.Text(colour, text) or text)
end

-- Fill the boxes from what's kept (on opening, and after Save or Clear).
local function Fill()
    local texts = RaidLead.Texts()
    for _, row in ipairs(frame.rows) do row.box:SetText(texts[row.key] or "") end
end

local function Save()
    local roster = Roster()
    local items = {}
    for _, row in ipairs(frame.rows) do
        local list, why = RaidLead.ParseLine(row.key, row.box:GetText(), roster)
        if not list then return SetStatus(row.label:GetText() .. ": " .. why, "bad") end
        for _, item in ipairs(list) do items[#items + 1] = item end
    end
    if #items > RaidLead.MAX_ITEMS then
        return SetStatus("At most " .. RaidLead.MAX_ITEMS .. " players across all the buffs.", "bad")
    end
    local ok, why = RaidLead.Set(items)
    if not ok then return SetStatus("Not saved: " .. why .. ".", "bad") end
    Fill()
    SetStatus(#items == 0 and "Cleared: the automatic split for every buff." or "Saved and sent to the raid.", "good")
    ns.BuffButton.Refresh()
end

local function Create()
    frame = CreateFrame("Frame", RaidLead.WINDOW, UIParent, "BasicFrameTemplateWithInset")
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, RaidLead.WINDOW) end
    frame:SetSize(560, 120 + #ORDER * ROW_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", 0, -5)
    frame.title:SetText("Raid buff assignments (experimental)")

    frame.hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.hint:SetPoint("TOPLEFT", 14, -32)
    frame.hint:SetPoint("RIGHT", -14, 0)
    frame.hint:SetJustifyH("LEFT")
    frame.hint:SetMaxLines(2)
    frame.hint:SetText("Who gives each buff, and to which groups, such as \"Ann Vale 1-4, Bob Lake 5-8\" "
        .. "(no groups: all of them). An empty line keeps the automatic split.")

    frame.rows = {}
    for i, buff in ipairs(ORDER) do
        local y = -70 - (i - 1) * ROW_HEIGHT
        local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("TOPLEFT", 16, y - 4)
        label:SetWidth(150)
        label:SetJustifyH("LEFT")
        label:SetText(ns.BuffData.SpellName(buff) or buff.key)
        local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
        box:SetSize(360, 20)
        box:SetPoint("TOPLEFT", 176, y)
        box:SetAutoFocus(false)
        box:SetMaxLetters(200)
        box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        frame.rows[i] = { key = buff.key, label = label, box = box }
    end

    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.status:SetPoint("BOTTOMLEFT", 16, 42)
    frame.status:SetPoint("RIGHT", -14, 0)
    frame.status:SetJustifyH("LEFT")
    frame.status:SetMaxLines(2)

    local save = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    save:SetSize(100, 22)
    save:SetPoint("BOTTOMRIGHT", -14, 12)
    save:SetText("Save")
    save:SetScript("OnClick", ns.Diag.Wrap(Save))
    frame.save = save

    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetSize(100, 22)
    clear:SetPoint("RIGHT", save, "LEFT", -8, 0)
    clear:SetText("Clear all")
    clear:SetScript("OnClick", ns.Diag.Wrap(function()
        for _, row in ipairs(frame.rows) do row.box:SetText("") end
        Save()
    end))
    frame.clear = clear

    local close = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    close:SetSize(90, 22)
    close:SetPoint("RIGHT", clear, "LEFT", -8, 0)
    close:SetText("Close")
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.close = close
end

-- Whether you may edit, and the line that says so.
function RaidLead.Refresh()
    if not frame or not frame:IsShown() then return end
    local me = Util.UnitFullName("player")
    local may = me ~= nil and RaidLead.MayAssign(me)
    for _, row in ipairs(frame.rows) do row.box:SetEnabled(may) end
    frame.save:SetEnabled(may)
    frame.clear:SetEnabled(may)
    if not may then
        SetStatus(InRaid() == true and "Only the raid leader and assistants can change these."
            or "You're not in a raid: there's nothing to assign.")
    end
end

-- /friendly raid: open the window (members see it read-only).
function RaidLead.Open()
    if not frame then Create() end
    frame:Show()
    SetStatus("")
    Fill()
    RaidLead.Refresh()
end

function RaidLead.Frame()
    return frame
end
