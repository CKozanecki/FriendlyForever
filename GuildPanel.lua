-- Guild leader controls (#496), part 3: the Guild page, under Friendly
-- Forever in the AddOns options. Every guildmate with the addon sees it:
--
-- - who leads: the guild master, and the ranks the guild master picks, with
--   who the roster shows at each rank. Only the guild master can change
--   them (decision 1), and the page asks them to, until they pick or say
--   only they lead for now;
-- - the guild's limits (decision 2): the most copies that greet one login,
--   the most that welcome a new member, and guild hellos on or off. A
--   leader changes them; everyone else sees them;
-- - who has Friendly Forever (decision 3): the guildmates whose copies
--   checked in, with their version and when they were last seen;
-- - the lines said recently (decision 4), on a leader's copy only, as only
--   a leader's copy keeps them, each with Veto;
-- - the vetoed lines, each with Undo for a leader.
--
-- The safety rule (owner, 18 Nov): nothing here can make anyone's copy say
-- new words or cast. Every change goes through GuildLead.Set, which takes
-- only tokens from each section's fixed grammar, and only from a leader.
-- Everything shown that came from the game or a guildmate (names, rank
-- names, the words seen in guild chat) is shown as plain text.
local _, ns = ...
local Util = ns.Util

local GuildPanel = {}
ns.GuildPanel = GuildPanel

GuildPanel.PAGE = "FriendlyForeverGuildPage"
GuildPanel.ROWS = 8              -- rows each list shows at once; Newer and Older page through the rest
GuildPanel.MAX_RANK_NAME = 32    -- bytes of a rank's name shown
GuildPanel.RANK_NAMES_SHOWN = 3  -- guildmates named after a rank; the rest are counted
GuildPanel.MAX_RANKS = 10        -- a guild's most ranks: the guild master's and nine more (Greeter.MAX_RANK)

------------------------------------------------------------------------
-- What the page shows and does, apart from its frames (tested directly)
------------------------------------------------------------------------

-- Who you are in the guild you're in now: "master", "leader" (a rank the
-- guild master picked), "member", or nil out of a guild or while the game
-- won't say which. When your own name or rank can't be read, "member":
-- the page then only shows.
function GuildPanel.Role()
    local GuildLead = ns.GuildLead
    if not GuildLead.Memory() then return nil end
    local me = Util.UnitFullName("player")
    if not me then return "member" end
    if GuildLead.IsGuildMaster(me) then return "master" end
    if GuildLead.IsLeader(me) then return "leader" end
    return "member"
end

-- How many ranks the guild has, the guild master's included: what the game
-- says, or when it won't, as many as the roster shows, or else every rank
-- a guild can have, so a rank is never left out.
function GuildPanel.NumRanks()
    local n = Util.ReadGameValues(GuildControlGetNumRanks)
    if type(n) == "number" and n == math.floor(n) and n >= 1 and n <= GuildPanel.MAX_RANKS then return n end
    local highest = 0
    for _, rank in pairs(ns.Greeter.MemberRanks()) do highest = math.max(highest, rank) end
    return highest > 0 and highest + 1 or GuildPanel.MAX_RANKS
end

-- A rank's name as the game gives it, as plain text, or "Rank <n>" when
-- it won't. index is the roster's rank index, 0 for the guild master; the
-- game numbers names from 1 for the guild master (unconfirmed on Forever:
-- #533), so the page also names who the roster shows at each rank.
function GuildPanel.RankName(index)
    local name = Util.ReadGameValues(GuildControlGetRankName, index + 1)
    if type(name) == "string" then
        name = Util.Utf8Truncate(Util.StripChat(name), GuildPanel.MAX_RANK_NAME)
        if name ~= "" then return name end
    end
    return string.format("Rank %d", index + 1)
end

-- The guildmates the roster shows at a rank, by name.
function GuildPanel.RankMembers(index)
    local out = {}
    for name, rank in pairs(ns.Greeter.MemberRanks()) do
        if rank == index then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

-- The rank indexes the page lists below the guild master's: every rank the
-- guild has, and any the guild master picked beyond them.
function GuildPanel.ShownRanks()
    local shown, out = {}, {}
    for index = 1, GuildPanel.NumRanks() - 1 do shown[index] = true end
    for _, item in ipairs(ns.GuildLead.Items("ranks")) do shown[tonumber(item)] = true end
    for index = 1, GuildPanel.MAX_RANKS - 1 do
        if shown[index] then out[#out + 1] = index end
    end
    return out
end

-- Whether a rank leads, as the guild's memory says.
function GuildPanel.RankLeads(index)
    for _, item in ipairs(ns.GuildLead.Items("ranks")) do
        if tonumber(item) == index then return true end
    end
    return false
end

-- The guild master picks whether a rank leads with them. Returns true, or
-- false and why (GuildLead.Set refuses anyone else).
function GuildPanel.SetRankLeads(index, on)
    local digit, out = tostring(index), {}
    for _, item in ipairs(ns.GuildLead.Items("ranks")) do
        if item ~= digit then out[#out + 1] = item end
    end
    if on then out[#out + 1] = digit end
    return ns.GuildLead.Set("ranks", out)
end

-- A leader sets one of the guild's limits: kind "g" (greeters per login) or
-- "w" (welcomes per new member) to a number, or nil for no limit; or kind
-- "h" (guild hellos) to true (on) or false (off). The other limits stay.
-- Returns true, or false and why.
function GuildPanel.SetCap(kind, value)
    local out = {}
    for _, item in ipairs(ns.GuildLead.Items("caps")) do
        if item:sub(1, 1) ~= kind then out[#out + 1] = item end
    end
    if kind == "h" then
        if value == false then out[#out + 1] = "h0" end
    elseif value ~= nil then
        out[#out + 1] = kind .. tostring(value)
    end
    return ns.GuildLead.Set("caps", out)
end

-- The next value a limit's stepper shows, in the order 1 to
-- GuildLead.CAP_MAX, then no limit (nil): - lowers it, never below 1;
-- + raises it, past CAP_MAX to no limit, which stays.
function GuildPanel.StepCap(value, by)
    local max = ns.GuildLead.CAP_MAX
    if value == nil then return by < 0 and max or nil end
    local n = value + by
    if n < 1 then return 1 end
    if n > max then return nil end
    return n
end

function GuildPanel.IsVetoed(token)
    return ns.GuildLead.IsVetoed(token)
end

-- A leader vetoes a line by its token. Returns true, or false and why.
function GuildPanel.Veto(token)
    local items = ns.GuildLead.Items("vetoes")
    for _, item in ipairs(items) do
        if item == token then return true end
    end
    if #items >= ns.GuildLead.MAX_VETOES then
        return false, string.format("the veto list is full (%d lines): undo one first", ns.GuildLead.MAX_VETOES)
    end
    items[#items + 1] = token
    return ns.GuildLead.Set("vetoes", items)
end

-- A leader undoes a veto. Returns true, or false and why.
function GuildPanel.Undo(token)
    local out = {}
    for _, item in ipairs(ns.GuildLead.Items("vetoes")) do
        if item ~= token then out[#out + 1] = item end
    end
    return ns.GuildLead.Set("vetoes", out)
end

-- The words of a line, by its token, where this copy knows them: a built-in
-- line's shipped words, what guild chat showed for a line reported
-- recently, or one of your own lines. Nil otherwise: a custom line's words
-- are never sent, only a hash of them.
function GuildPanel.LineText(token)
    local GuildLead = ns.GuildLead
    local text = GuildLead.BuiltInText(token)
    if text then return text end
    local lines = GuildLead.RecentLines()
    for i = #lines, 1, -1 do
        if lines[i].token == token and lines[i].text then return lines[i].text end
    end
    for msgType in pairs(GuildLead.LINE_TYPES) do
        local section = type(ns.db) == "table" and ns.db[msgType]
        local messages = type(section) == "table" and section.messages
        if type(messages) == "table" then
            for _, line in ipairs(messages) do
                if type(line) == "string" and GuildLead.LineToken(msgType, line) == token then return line end
            end
        end
    end
    return nil
end

-- A line's type, by its token: a built-in line names it; a custom line's
-- token doesn't. Nil when it can't be told.
function GuildPanel.LineType(token)
    local letter = type(token) == "string" and token:match("^b([lj])")
    if letter == "l" then return "guildLogin" end
    if letter == "j" then return "guildJoin" end
    return nil
end

-- How long ago a time on the clock GuildLead keeps was, in words.
function GuildPanel.Ago(seen)
    local now = ns.GuildLead.Now()
    if type(seen) ~= "number" or now <= 0 or seen >= now then return "just now" end
    local seconds = now - seen
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return string.format("%d min ago", math.floor(seconds / 60)) end
    if seconds < 2 * 86400 then return string.format("%d h ago", math.floor(seconds / 3600)) end
    return string.format("%d days ago", math.floor(seconds / 86400))
end

-- The guildmates seen with the addon, most recently first: { name,
-- version, seen }.
function GuildPanel.MateList()
    local list = {}
    for name, mate in pairs(ns.GuildLead.Mates()) do
        list[#list + 1] = { name = name, version = mate.version, seen = mate.seen }
    end
    table.sort(list, function(a, b)
        if a.seen ~= b.seen then return a.seen > b.seen end
        return a.name < b.name
    end)
    return list
end

-- The lines said recently, newest first.
function GuildPanel.LineList()
    local lines, out = ns.GuildLead.RecentLines(), {}
    for i = #lines, 1, -1 do out[#out + 1] = lines[i] end
    return out
end

-- The vetoed lines' tokens, in the order the guild keeps them.
function GuildPanel.VetoList()
    return ns.GuildLead.Items("vetoes")
end

-- The note on the Guild Login and Guild Join tabs when the guild's settings
-- limit yours (decision 6), or nil when they don't.
function GuildPanel.LimitNote(msgType)
    local GuildLead = ns.GuildLead
    if not GuildLead.LINE_TYPES[msgType] or not GuildLead.Memory() then return nil end
    local caps, parts = GuildLead.Caps(), {}
    if msgType == "guildLogin" then
        local own = ns.Config.Field("guildLogin", "maxGreeters")
        if caps.hellos == false then
            parts[#parts + 1] = "Your guild has turned guild hellos off: no copy in the guild greets a login."
        elseif caps.greeters and type(own) == "number" and caps.greeters < own then
            parts[#parts + 1] = string.format("Your guild lets at most %d greet one login, so that's used, not "
                .. "your %d.", caps.greeters, own)
        end
    elseif caps.welcomes then
        parts[#parts + 1] = string.format("Your guild lets at most %d welcome a new member, a few seconds apart, "
            .. "with different lines.", caps.welcomes)
    end
    local section = ns.db[msgType]
    local messages = type(section) == "table" and section.messages
    local vetoed = 0
    if type(messages) == "table" then
        for _, line in ipairs(messages) do
            if type(line) == "string" and line:find("%S") and GuildLead.IsLineVetoed(msgType, line) then
                vetoed = vetoed + 1
            end
        end
    end
    if vetoed == 1 then
        parts[#parts + 1] = "One of these lines is vetoed by your guild, so it's never said."
    elseif vetoed > 1 then
        parts[#parts + 1] = string.format("%d of these lines are vetoed by your guild, so they're never said.",
            vetoed)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, " ") .. " (Guild page)"
end

------------------------------------------------------------------------
-- The page
------------------------------------------------------------------------

local page
local w = {}
GuildPanel.frames = w -- exposed for tests
local offsets = { mates = 0, lines = 0, vetoes = 0 } -- the first row each list shows

GuildPanel.ROLE_TEXT = {
    master = "You're the guild master: you pick the ranks that lead with you, and leaders set the guild's "
        .. "limits and vetoes.",
    leader = "Your rank leads: you set the guild's limits and vetoes. Only the guild master picks who leads.",
    member = "Only the guild master and the ranks the guild master picks change these. They only ever make "
        .. "the addon quieter, and your own lower settings stay.",
}
GuildPanel.NOT_IN_GUILD = "You're not in a guild, or the game hasn't said which yet."
GuildPanel.ASK_RANKS = "Pick the ranks that lead with you (your officers, say): they can then set the guild's "
    .. "limits and vetoes too. Until you pick some, only you lead."
GuildPanel.ROWS_EMPTY = {
    mates = "No guildmate's copy has checked in yet.",
    lines = "No guild line said since you logged in.",
    vetoes = "No line is vetoed.",
}
GuildPanel.LINES_MEMBER = "A leader's copy lists the lines each copy says in guild chat, with Veto on each."

local function Say(ok, why)
    if not ok then ns.Print(why or "that didn't work") end
    GuildPanel.Refresh()
end

-- [-] value [+] for one of the guild's limits.
local function CapStepper(UI, parent, text, kind)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(560, 24)
    row.label = UI.Label(row, text)
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.minus = UI.Button(row, "-", 24, function() row.Step(-1) end)
    row.minus:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
    row.value = UI.Label(row, "", "GameFontHighlight")
    row.value:SetPoint("LEFT", row.minus, "RIGHT", 6, 0)
    row.value:SetWidth(64)
    row.value:SetJustifyH("CENTER")
    row.plus = UI.Button(row, "+", 24, function() row.Step(1) end)
    row.plus:SetPoint("LEFT", row.value, "RIGHT", 6, 0)
    function row.Current()
        local caps = ns.GuildLead.Caps()
        if kind == "g" then return caps.greeters end
        return caps.welcomes
    end
    function row.Step(by)
        Say(GuildPanel.SetCap(kind, GuildPanel.StepCap(row.Current(), by)))
    end
    function row.Fill(canEdit)
        local n = row.Current()
        row.value:SetText(n and tostring(n) or "no limit")
        row.minus:SetEnabled(canEdit)
        row.plus:SetEnabled(canEdit)
    end
    return row
end

-- A row of a list: a button at its left (Veto or Undo) and a line of text.
local function ListRow(UI, parent, withButton)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(560, 22)
    local left = row
    if withButton then
        row.button = UI.Button(row, "", 64, function() if row.onClick then row.onClick() end end)
        row.button:SetPoint("LEFT", row, "LEFT", 0, 0)
        left = row.button
    end
    row.words = UI.Label(row, "", "GameFontHighlightSmall")
    row.words:SetPoint("LEFT", left, withButton and "RIGHT" or "LEFT", withButton and 8 or 0, 0)
    row.words:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    -- One line each, cut with "…" when long: a row that wrapped would
    -- overlap the next (#52).
    row.words:SetWordWrap(false)
    return row
end

-- Newer and Older for a list, with which rows show.
local function Pager(UI, parent, list)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(560, 22)
    row.newer = UI.Button(row, "Newer", 70, function()
        offsets[list] = math.max(0, offsets[list] - GuildPanel.ROWS)
        GuildPanel.Refresh()
    end)
    row.newer:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.older = UI.Button(row, "Older", 70, function()
        offsets[list] = offsets[list] + GuildPanel.ROWS
        GuildPanel.Refresh()
    end)
    row.older:SetPoint("LEFT", row.newer, "RIGHT", 6, 0)
    row.count = UI.Label(row, "", "GameFontHighlightSmall")
    row.count:SetPoint("LEFT", row.older, "RIGHT", 10, 0)
    return row
end

-- Stack the shown regions top to bottom, each item { region, x, gap }: x
-- from the content's left, gap above it. A hidden region takes no room.
local function Stack(content, items)
    local prev, prevX
    for _, item in ipairs(items) do
        local region = item[1]
        if region:IsShown() then
            region:ClearAllPoints()
            if prev then
                region:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", item[2] - prevX, -(item[3] or 6))
            else
                region:SetPoint("TOPLEFT", content, "TOPLEFT", item[2], -12)
            end
            if item.wrap then region:SetPoint("RIGHT", content, "RIGHT", -24, 0) end
            prev, prevX = region, item[2]
        end
    end
end

function GuildPanel.Create()
    local Options = ns.Options
    local UI = Options.UI
    page = UI.SubPage("Guild", "Guild", GuildPanel.PAGE)
    local content = UI.ScrollArea(page, 1600)
    local widgets = Options.widgets.guild

    local function Note(text)
        local label = UI.Label(content, text or "", "GameFontHighlightSmall")
        label:SetWordWrap(true)
        return label
    end
    local function Header(text) return UI.Label(content, text, "GameFontNormal") end

    w.role = Note()
    w.ask = Note(ns.Colours.Text("warn", GuildPanel.ASK_RANKS))
    widgets.onlyMe = UI.Button(content, "Only me for now", 130, function()
        ns.GuildLead.MarkRanksAsked()
        GuildPanel.Refresh()
    end)

    w.leadsHeader = Header("Who leads")
    w.master = Note()
    w.ranks = {}
    widgets.ranks = {}
    for index = 1, GuildPanel.MAX_RANKS - 1 do
        local cb = UI.Checkbox(content, "", function(on) Say(GuildPanel.SetRankLeads(index, on)) end)
        cb.members = UI.Label(cb, "", "GameFontHighlightSmall")
        cb.members:SetPoint("LEFT", cb.label, "RIGHT", 8, 0)
        cb.members:SetWordWrap(false)
        w.ranks[index] = cb
        widgets.ranks[index] = cb
    end
    w.ranksNote = Note("Only the guild master picks who leads. The names are the ranks' as the game gives them; "
        .. "who is at each is read from the guild roster.")

    w.limitsHeader = Header("The guild's limits")
    w.greeters = CapStepper(UI, content, "Guild limit: most copies that greet one login:", "g")
    w.welcomes = CapStepper(UI, content, "Guild limit: most copies that welcome a new member:", "w")
    widgets.greeters = { minus = w.greeters.minus, plus = w.greeters.plus }
    widgets.welcomes = { minus = w.welcomes.minus, plus = w.welcomes.plus }
    widgets.hellos = UI.Checkbox(content, "Guild hellos on for the whole guild", function(on)
        Say(GuildPanel.SetCap("h", on))
    end)
    w.limitsNote = Note("Each copy keeps the lower of the guild's limit and its own setting. With no limit on "
        .. "welcomes, every copy welcomes a new member at once.")

    w.matesHeader = Header("Who has Friendly Forever")
    w.matesCount = Note()
    w.mates = {}
    for i = 1, GuildPanel.ROWS do w.mates[i] = ListRow(UI, content, false) end
    w.matesPager = Pager(UI, content, "mates")
    widgets.matesPager = { newer = w.matesPager.newer, older = w.matesPager.older }

    w.linesHeader = Header("Lines said recently")
    w.linesNote = Note()
    w.lines = {}
    widgets.lines = {}
    for i = 1, GuildPanel.ROWS do
        w.lines[i] = ListRow(UI, content, true)
        widgets.lines[i] = w.lines[i].button
    end
    w.linesPager = Pager(UI, content, "lines")
    widgets.linesPager = { newer = w.linesPager.newer, older = w.linesPager.older }

    w.vetoesHeader = Header("Vetoed lines")
    w.vetoesCount = Note()
    w.vetoes = {}
    widgets.vetoes = {}
    for i = 1, GuildPanel.ROWS do
        w.vetoes[i] = ListRow(UI, content, true)
        widgets.vetoes[i] = w.vetoes[i].button
    end
    w.vetoesPager = Pager(UI, content, "vetoes")
    widgets.vetoesPager = { newer = w.vetoesPager.newer, older = w.vetoesPager.older }

    w.content = content
    page:SetScript("OnShow", function() GuildPanel.Fill() end)
    -- The guild's memory changes as messages come in: the page, and the
    -- note on the guild tabs, follow, once on the next frame however many
    -- came. Options.Refresh refills each page that's open, this one too.
    local queued = false
    ns.GuildLead.onChange = function()
        if queued then return end
        queued = true
        C_Timer.After(0, ns.Diag.Wrap(function()
            queued = false
            ns.Options.Refresh()
        end))
    end
end

-- Fill a list's rows from its items, a page at a time.
local function FillList(rows, pager, list, items, describe)
    local total = #items
    if offsets[list] >= total then offsets[list] = math.max(0, total - (total - 1) % GuildPanel.ROWS - 1) end
    local first = offsets[list]
    for i, row in ipairs(rows) do
        local item = items[first + i]
        row:SetShown(item ~= nil)
        if item then describe(row, item) end
    end
    pager:SetShown(total > GuildPanel.ROWS)
    pager.newer:SetEnabled(first > 0)
    pager.older:SetEnabled(first + GuildPanel.ROWS < total)
    pager.count:SetText(total > 0 and string.format("%d to %d of %d", first + 1,
        math.min(first + GuildPanel.ROWS, total), total) or "")
end

local function TypeLabel(msgType)
    local info = msgType and ns.Config.TYPE_INFO[msgType]
    return info and info.label or "Guild line"
end

-- A line's words for a row, quoted, or what's known of it.
local function Words(token, text)
    if text then return "\"" .. ns.Diag.Safe(text) .. "\"" end
    if GuildPanel.LineType(token) then return "a built-in line" end
    return ns.Colours.Text("muted", "a line of their own (its words weren't seen here)")
end

function GuildPanel.Fill()
    if not page then return end
    local widgets = ns.Options.widgets.guild
    local role = GuildPanel.Role()
    local inGuild = role ~= nil
    local canLead = role == "master" or role == "leader"
    local items = {}
    local function Add(region, x, gap, wrap)
        items[#items + 1] = { region, x, gap, wrap = wrap }
    end

    w.role:SetText(inGuild and GuildPanel.ROLE_TEXT[role] or GuildPanel.NOT_IN_GUILD)
    Add(w.role, 16, 0, true)
    local ask = role == "master" and not ns.GuildLead.RanksAsked()
    w.ask:SetShown(ask)
    widgets.onlyMe:SetShown(ask)
    Add(w.ask, 16, 10, true)
    Add(widgets.onlyMe, 16, 6)

    -- Every section shows only in a guild.
    local sections = { w.leadsHeader, w.master, w.ranksNote, w.limitsHeader, w.greeters, w.welcomes,
        widgets.hellos, w.limitsNote, w.matesHeader, w.matesCount, w.linesHeader, w.linesNote, w.vetoesHeader,
        w.vetoesCount }
    for _, region in ipairs(sections) do region:SetShown(inGuild) end

    -- Who leads.
    Add(w.leadsHeader, 16, 20)
    local masters = GuildPanel.RankMembers(0)
    w.master:SetText(string.format("%s: %s. The guild master always leads.", ns.Diag.Safe(GuildPanel.RankName(0)),
        #masters > 0 and ns.Diag.Safe(masters[1]) or "not in the roster as read"))
    Add(w.master, 16, 6, true)
    local shown = {}
    for _, index in ipairs(inGuild and GuildPanel.ShownRanks() or {}) do shown[index] = true end
    for index, cb in ipairs(w.ranks) do
        cb:SetShown(shown[index] == true)
        cb:SetEnabled(role == "master")
        if shown[index] then
            cb.label:SetText(ns.Diag.Safe(GuildPanel.RankName(index)))
            cb:SetChecked(GuildPanel.RankLeads(index))
            local members = GuildPanel.RankMembers(index)
            local named = {}
            for i = 1, math.min(#members, GuildPanel.RANK_NAMES_SHOWN) do named[i] = ns.Diag.Safe(members[i]) end
            local text = #members == 0 and "nobody in the roster" or table.concat(named, ", ")
            if #members > GuildPanel.RANK_NAMES_SHOWN then
                text = text .. string.format(" and %d more", #members - GuildPanel.RANK_NAMES_SHOWN)
            end
            cb.members:SetText(ns.Colours.Text("muted", text))
        end
        Add(cb, 12, 2)
    end
    Add(w.ranksNote, 16, 4, true)

    -- The guild's limits.
    Add(w.limitsHeader, 16, 20)
    w.greeters.Fill(canLead)
    w.welcomes.Fill(canLead)
    widgets.hellos:SetChecked(ns.GuildLead.Caps().hellos ~= false)
    widgets.hellos:SetEnabled(canLead)
    Add(w.greeters, 16, 6, true)
    Add(w.welcomes, 16, 4, true)
    Add(widgets.hellos, 12, 4)
    Add(w.limitsNote, 16, 4, true)

    -- Who has Friendly Forever.
    Add(w.matesHeader, 16, 20)
    local mates = inGuild and GuildPanel.MateList() or {}
    w.matesCount:SetText(#mates == 0 and GuildPanel.ROWS_EMPTY.mates
        or string.format("%d guildmates' copies checked in, newest first. Each checks in after logging in, "
            .. "then every 15 minutes.", #mates))
    Add(w.matesCount, 16, 6, true)
    FillList(w.mates, w.matesPager, "mates", mates, function(row, mate)
        local leads = ns.GuildLead.IsLeader(mate.name) and ns.Colours.Text("good", "  leads") or ""
        row.words:SetText(string.format("%s  %s  %s%s", ns.Diag.Safe(mate.name),
            ns.Colours.Text("muted", "version " .. ns.Diag.Safe(mate.version)), GuildPanel.Ago(mate.seen), leads))
    end)
    for _, row in ipairs(w.mates) do Add(row, 16, 2, true) end
    Add(w.matesPager, 16, 4, true)

    -- Lines said recently (a leader's copy only keeps them).
    Add(w.linesHeader, 16, 20)
    local lines = (inGuild and canLead) and GuildPanel.LineList() or {}
    local full = #GuildPanel.VetoList() >= ns.GuildLead.MAX_VETOES
    w.linesNote:SetText(not canLead and GuildPanel.LINES_MEMBER or (#lines == 0 and GuildPanel.ROWS_EMPTY.lines
        or "The guild lines each copy said, newest first. Veto one and no copy in the guild says it again."))
    Add(w.linesNote, 16, 6, true)
    FillList(w.lines, w.linesPager, "lines", lines, function(row, line)
        local vetoed = GuildPanel.IsVetoed(line.token)
        row.button:SetText(vetoed and "Undo" or "Veto")
        row.button:SetEnabled(canLead and (vetoed or not full))
        row.onClick = function()
            if vetoed then Say(GuildPanel.Undo(line.token)) else Say(GuildPanel.Veto(line.token)) end
        end
        local state = vetoed and ns.Colours.Text("bad", "vetoed  ") or ""
        row.words:SetText(string.format("%s%s  %s, %s: %s", state, TypeLabel(line.msgType), ns.Diag.Safe(line.sender),
            GuildPanel.Ago(line.seen), Words(line.token, line.text)))
    end)
    for _, row in ipairs(w.lines) do Add(row, 16, 2, true) end
    Add(w.linesPager, 16, 4, true)

    -- Vetoed lines.
    Add(w.vetoesHeader, 16, 20)
    local vetoes = inGuild and GuildPanel.VetoList() or {}
    w.vetoesCount:SetText(#vetoes == 0 and GuildPanel.ROWS_EMPTY.vetoes
        or string.format("%d of at most %d. No copy in the guild says these.%s", #vetoes, ns.GuildLead.MAX_VETOES,
            canLead and " Undo lets them be said again." or ""))
    Add(w.vetoesCount, 16, 6, true)
    FillList(w.vetoes, w.vetoesPager, "vetoes", vetoes, function(row, token)
        row.button:SetText("Undo")
        row.button:SetShown(canLead)
        row.onClick = function() Say(GuildPanel.Undo(token)) end
        row.words:SetText(string.format("%s: %s", TypeLabel(GuildPanel.LineType(token)),
            Words(token, GuildPanel.LineText(token))))
    end)
    for _, row in ipairs(w.vetoes) do Add(row, 16, 2, true) end
    Add(w.vetoesPager, 16, 4, true)

    Stack(w.content, items)
    ns.Options.UI.Refit(page.scroll, page.content)
end

-- Refill the page when it's open (settings changes, the guild's memory).
function GuildPanel.Refresh()
    if page and ns.Options.UI.IsOpen(page) then GuildPanel.Fill() end
end

function GuildPanel.Page()
    return page
end

function GuildPanel.Open()
    if page then ns.Options.OpenPage(page) end
end
