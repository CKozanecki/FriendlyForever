-- luacheck configuration. WoW runs Lua 5.1; anything the addon writes to the
-- global environment must be listed in `globals`, so accidental global leaks
-- (which can taint Blizzard UI code) fail the lint.
std = "lua51"
max_line_length = 120
exclude_files = { ".tools/**", "dist/**", ".release/**" }

-- The addon may only create these globals.
globals = {
    "FriendlyForeverDB",
    "FriendlyForeverTextWindow",
    "SLASH_FRIENDLYFOREVER1",
    "SLASH_FRIENDLYFOREVER2",
    SlashCmdList = { fields = { "FRIENDLYFOREVER" } },
}

-- WoW API the addon reads.
read_globals = {
    "C_ChatInfo", "UnitFullName", "GetUnitName", "C_GuildInfo", "C_Timer", "CreateFrame",
    "DEFAULT_CHAT_FRAME", "GameTooltip", "GetCursorPosition", "GetGuildRosterInfo",
    "GetNumGuildMembers", "GetTime", "GuildRoster", "InCombatLockdown",
    "InterfaceOptionsFrame_OpenToCategory", "InterfaceOptions_AddCategory",
    "IsInGroup", "IsInGuild", "IsInInstance", "IsInRaid", "LE_PARTY_CATEGORY_INSTANCE",
    "Minimap", "SendChatMessage", "Settings", "UIParent", "UnitCanAttack",
    "UnitInParty", "UnitInRaid", "UnitIsGroupLeader", "UnitIsPlayer", "UnitIsUnit", "UnitName", "UnitExists",
    "UnitIsAFK",
    "issecretvalue", "issecrettable", "date", "C_UnitAuras", "C_AddOns", "geterrorhandler",
    "ERR_FRIEND_ONLINE_SS", "ERR_GUILD_JOIN_S", "ERR_JOINED_GROUP_S",
    "ERR_RAID_MEMBER_ADDED_S", "ERR_INSTANCE_GROUP_ADDED_S", "ERR_CHAT_PLAYER_NOT_FOUND_S",
    "C_CVar", "GetCVar", "SetCVar",
    "time", "DoEmote", "UnitClass", "UnitRace", "UnitFactionGroup", "GetRealZoneText", "GetZoneText",
    "GetGameTime", "IsResting", "AddonCompartmentFrame", "UISpecialFrames",
}

-- Tests run in plain Lua with busted and install the mock WoW API globally.
files["spec/**"] = {
    std = "+busted",
    globals = { "_G" },
    allow_defined_top = true,
    max_line_length = false,
    ignore = { "122", "142", "143" }, -- tests set fields on global tables
}
