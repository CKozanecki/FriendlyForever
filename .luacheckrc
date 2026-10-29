-- luacheck configuration. WoW runs Lua 5.1; anything the addon writes to the
-- global environment must be listed in `globals`, so accidental global leaks
-- (which can taint Blizzard UI code) fail the lint.
std = "lua51"
max_line_length = 120
-- .claude/worktrees holds other checkouts of this repo (Claude Code side sessions).
exclude_files = { ".tools/**", "dist/**", ".release/**", ".claude/**" }

-- The addon may only create these globals.
globals = {
    "FriendlyForeverDB",
    "FriendlyForeverTextWindow",
    "FriendlyForeverGeneralPage", -- the options pages, named for the UI simulator's scenarios (#52)
    "FriendlyForeverLedgerPage",
    "FriendlyForeverBuffButton",
    "FriendlyForever_ToggleBuffMode", -- called by its key binding (Bindings.xml)
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
    "C_Spell", "C_SpellBook", "Enum", "GetCVarBool", "GetSpellInfo", "GetSpellTexture", "IsSpellKnown", "IsPlayerSpell",
    "UnitIsDeadOrGhost", "UnitIsPVP",
    "SetOverrideBindingClick", "ClearOverrideBindings", "GetBindingText", "GetBindingAction",
    "IsShiftKeyDown", "IsControlKeyDown", "IsAltKeyDown",
    "UnitInRange", "UnitIsConnected", "UnitIsVisible", "IsSpellInRange",
    "UnitGroupRolesAssigned", "GetPartyAssignment", "GetBattlefieldWinner",
}

-- Tests run in plain Lua with busted and install the mock WoW API globally.
files["spec/**"] = {
    std = "+busted",
    globals = { "_G" },
    allow_defined_top = true,
    max_line_length = false,
    ignore = { "122", "142", "143" }, -- tests set fields on global tables
}

-- UI scenarios run inside the wow-ui-sim simulator (issue #49), which
-- provides the test functions and A_Print.
files["uitests/**"] = {
    -- C_SpellBook and C_Spell: the spellbook fixture in button_states.lua
    -- answers for one spell while a scenario runs (#83).
    -- FriendlyForeverDB: pages.lua fills the saved settings the phase 1 pages
    -- show, and puts them back (#52).
    globals = { "_G", "DEFAULT_CHAT_FRAME", "C_SpellBook", "C_Spell", "FriendlyForeverUIStates",
        "FriendlyForeverUIPages", "FriendlyForeverDB" },
    read_globals = {
        "test", "assertTrue", "assertType", "assertEquals", "assertNotNil",
        "print", "A_Print", "A_Admin", "UIParent",
        "SLASH_FRIENDLYFOREVER1", "SlashCmdList",
        "GetTime", "UnitClass", "UnitInRange", "UnitExists", "UnitName", "UnitLevel", "InCombatLockdown",
        "C_UnitAuras",
        "geterrorhandler", "seterrorhandler", "debugprofilestop",
        "Settings", "time", "date",
    },
}
