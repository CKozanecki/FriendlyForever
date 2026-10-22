-- Recognises the system messages we react to, using the client's own
-- localized format strings so it works in every language.
local _, ns = ...
local Util = ns.Util

local Parser = {}
ns.Parser = Parser

local rules

function Parser.Build()
    rules = {}
    local function Add(kind, fmt)
        local pattern = Util.FormatToPattern(fmt)
        if pattern then rules[#rules + 1] = { kind = kind, pattern = pattern } end
    end
    -- Same message is used for friends; the greeter checks the guild roster.
    Add("guildOnline", ERR_FRIEND_ONLINE_SS)
    Add("guildJoin", ERR_GUILD_JOIN_S)
    Add("partyJoin", ERR_JOINED_GROUP_S)
    Add("partyJoin", ERR_RAID_MEMBER_ADDED_S)
    Add("partyJoin", ERR_INSTANCE_GROUP_ADDED_S)
    Add("whisperFailed", ERR_CHAT_PLAYER_NOT_FOUND_S)
end

-- Returns kind, full player name for a recognised message; nil otherwise.
function Parser.Parse(msg)
    if Util.IsSecret(msg) or type(msg) ~= "string" then return nil end
    if not rules then Parser.Build() end
    for _, rule in ipairs(rules) do
        local captured = msg:match(rule.pattern)
        if captured then
            local name = Util.FullName(captured)
            if name then return rule.kind, name end
            return nil
        end
    end
    return nil
end
