-- Buff requests in chat (#40): a player who whispers you, or says in /say
-- or party chat (the owner, on #40), a short request for one of your buffs ("mark pls", "can i get int?") is
-- queued on the buff-back button for that buff. Nothing here casts or sends
-- anything: the button casts only on your press (BuffButton.lua), and no
-- reply goes to chat. Off by default (the owner's decision on #40).
--
-- Chat text is untrusted. It is never used as a pattern, a macro or a
-- message: fixed leads and tails are cut from it, and what is left must
-- equal, as plain text, one of a fixed list of buff names and nicknames for
-- your own class's buffs (those you know and offer). So a message with an
-- escape code ("|"), a link, a digit or any other character, one too long
-- to be a short request, or anything else around the buff's name, queues
-- nobody. The sender's name goes on the button only through the same
-- checks as a favour's (Util.FullName, then BuffButton's macro check). A
-- secret text or sender (chat inside an instance can be) queues nobody.
--
-- Limits (Offers.lua): one request per player, at most Offers.MAX_REQUESTS
-- waiting at once (the oldest goes first), kept apart from favours so a
-- flood of requests never pushes a favour out, and expiring with the
-- favours' "Offer for" time. Your ignore list, snooze, a battleground's
-- quiet and the capital-city quiet (whenever the button is hidden there)
-- drop a request as it arrives.
local _, ns = ...
local Util = ns.Util

local Requests = {}
ns.Requests = Requests

-- The longest message read as a request, in bytes: the longest phrasing
-- ("could i have power word fortitude please") fits; anything longer is chat.
Requests.MAX_TEXT_BYTES = 64

-- The names a request may use for each buff, by buff key: English, lower
-- case, words separated by single spaces, no punctuation (a request's own
-- punctuation is dropped before comparing). The game's own spelling of the
-- spell's name counts too (BuffData.SpellName), whatever the client's
-- language. Battle Shout has none: it only reaches your own party.
Requests.NICKNAMES = {
    motw = { "mark", "motw", "mark of the wild", "gotw", "gift", "gift of the wild" },
    thorns = { "thorns" },
    intellect = { "int", "intellect", "ai", "arcane intellect", "ab", "brilliance", "arcane brilliance" },
    kings = { "kings", "bok", "blessing of kings" },
    wisdom = { "wisdom", "wis", "bow", "blessing of wisdom" },
    might = { "might", "bom", "blessing of might" },
    fortitude = { "fort", "fortitude", "pwf", "stam", "stamina", "power word fortitude" },
    spirit = { "spirit", "ds", "divine spirit" },
    shadow = { "shadow prot", "shadow protection", "sprot" },
    -- A shaman's Water Breathing and a warlock's Unending Breath do the same
    -- job, so players ask for either by either name (the owner, on #40).
    waterbreathing = "breathing",
    breath = "breathing",
}
-- Lists more than one buff shares, by name: a buff above may name one.
Requests.SHARED_NICKNAMES = {
    breathing = { "water breathing", "wb", "unending breath", "ub", "breath" },
}

-- The names a request may use for buff (a key of NICKNAMES).
function Requests.NamesFor(key)
    local names = Requests.NICKNAMES[key]
    if type(names) == "string" then names = Requests.SHARED_NICKNAMES[names] end
    return type(names) == "table" and names or {}
end

-- What may come before the buff's name, and after it. Each is a whole
-- word or words, compared as plain text; a longer lead is tried first.
Requests.LEADS = { "could i have", "could i get", "can i have", "can i get", "can i haz", "may i have",
    "need some", "got any", "any", "need", "got" }
Requests.TAILS = { "please", "plox", "pls", "plz", "thx", "ty" }

-- Whether text starts with word followed by a space; the rest if so.
local function AfterLead(text, lead)
    if text:sub(1, #lead + 1) == lead .. " " then return text:sub(#lead + 2) end
end

-- Whether text ends with a space and word; the rest if so.
local function BeforeTail(text, tail)
    if text:sub(-(#tail + 1)) == " " .. tail then return text:sub(1, -(#tail + 2)) end
end

-- The buff name a message asks for, as typed (lower case, single spaces),
-- or nil when it isn't a short request. Only fixed patterns are used on it:
-- nothing from the text becomes a pattern.
function Requests.Phrase(text)
    if Util.IsSecret(text) or type(text) ~= "string" then return nil end
    if #text > Requests.MAX_TEXT_BYTES then return nil end
    -- Lower case, and the punctuation a request uses ends words. Anything
    -- else (an escape code, a digit, another script) stays, so the phrase
    -- left can't equal any name.
    local s = text:lower():gsub("[%?!%.,:]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    for _, lead in ipairs(Requests.LEADS) do
        local rest = AfterLead(s, lead)
        if rest then
            s = rest
            break
        end
    end
    -- Up to two polite words at the end ("pls ty").
    for _ = 1, 2 do
        local cut
        for _, tail in ipairs(Requests.TAILS) do
            cut = BeforeTail(s, tail)
            if cut then break end
        end
        if not cut then break end
        s = cut
    end
    -- An empty phrase ("pls" alone) equals no name, so it queues nobody.
    return s
end

-- The spell's name as the game spells it, as a request would type it.
local function Spoken(name)
    if type(name) ~= "string" then return nil end
    local s = name:lower():gsub("[%?!%.,:]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return s
end

-- The buff of yours that a phrase names, or nil: one you know and offer
-- (BuffData.Offerable, which holds no self-buff such as Battle Shout: #44).
function Requests.BuffFor(phrase)
    if type(phrase) ~= "string" then return nil end
    for _, buff in ipairs(ns.BuffData.Offerable()) do
        for _, nick in ipairs(Requests.NamesFor(buff.key)) do
            if nick == phrase then return buff end
        end
        if Spoken(ns.BuffData.SpellName(buff)) == phrase then return buff end
    end
    return nil
end

-- A setting read defensively: damaged mid-session reads as off.
local function On()
    local cfg = ns.db and ns.db.buffBack
    return type(cfg) == "table" and cfg.enabled == true and cfg.requests == true
end

-- Whether requests are listened for now: the addon, buff back and the
-- setting are on. Core registers the chat events only then.
function Requests.Listening()
    return ns.db ~= nil and ns.db.enabled == true and On()
end

-- Why a request from name can't be queued now, or nil when it can.
local function Refused(name)
    if not ns.Announcer.IsWatching() then return ns.Announcer.ActiveState() end
    if ns.Announcer.SnoozeLeft() then return "snoozed" end
    if ns.Battleground.Quiet() then return ns.Battleground.QuietReason() end
    if ns.Cities.ButtonHidden() then return "quiet in a capital city" end
    if ns.Ignore.Has(name) then return "on your ignore list" end
    if name == Util.UnitFullName("player") then return "it's you" end
    return nil
end

-- A chat message (CHAT_MSG_WHISPER, CHAT_MSG_SAY, CHAT_MSG_PARTY or
-- CHAT_MSG_PARTY_LEADER: text, sender). where
-- says which, for the debug log.
local function OnChat(where, text, sender)
    if not Requests.Listening() then return end
    local phrase = Requests.Phrase(text)
    if not phrase then return end
    local buff = Requests.BuffFor(phrase)
    if not buff then return end
    -- The sender as the game names them: a whole name, "First-Surname" or
    -- "First Surname" (assumed, unconfirmed: #352). A first name alone can't
    -- be matched to anyone the game shows, so it is no request.
    local name = Util.FullName(sender)
    if not name or not name:find("-", 1, true) then return end
    local why = Refused(name)
    if why then
        ns.Diag.Log("requests", "not queuing %s's request (%s): %s", name, where, why)
        return
    end
    local ok, reason = ns.Offers.Request(name, buff)
    if ok then
        ns.Diag.Log("requests", "%s asked for %s (%s)", name, buff.key, where)
    else
        ns.Diag.Log("requests", "not queuing %s's request (%s): %s", name, where, reason)
    end
end

-- The Buff Back tab's switch, and its tooltip.
Requests.LABEL = "Offer my buffs to players who ask in chat"
Requests.TOOLTIP = "When someone whispers you, or says in /say or party chat, a short request for one of your buffs "
    .. "(\"mark pls\", \"can I get int?\"), the buff-back button offers them that buff. It never casts by "
    .. "itself, and nothing is said in chat. Your ignore list, snooze and the quiet in capital cities and "
    .. "battlegrounds apply."
-- Turn requests on or off from the switch. Off lets every waiting request
-- go (ns.RefreshEvents, whatever turned them off), so none is offered after
-- you said no to them. It writes through Config.Section, so a Buff Back
-- section damaged mid-session is repaired first, not an error (#330).
function Requests.SetEnabled(on)
    ns.Config.Section("buffBack").requests = on and true or false
    ns.RefreshEvents()
    ns.BuffButton.Refresh()
end

function Requests.OnWhisper(text, sender) OnChat("whisper", text, sender) end
function Requests.OnSay(text, sender) OnChat("/say", text, sender) end
-- Party chat, from a member or the party's leader (CHAT_MSG_PARTY_LEADER).
function Requests.OnParty(text, sender) OnChat("party", text, sender) end
