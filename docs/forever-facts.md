# WoW Forever facts

Game and API facts the addon's code depends on, so each session doesn't have to research them again. **Facts only:** each one gives its source, or the issue where it was researched and sourced. Anything that can't be confirmed until launch (Nov 5) is marked **launch check**, with a link to its item on #50.

WoW Forever isn't Classic Era (CLAUDE.md's "Issues and specs"). Check new facts against Forever sources (Wowhead's `/forever/` pages, patch notes), put the sources on the issue, and add the fact here in the same PR. When a launch check is settled, update its line here. Where this file and CONTRIBUTING.md differ, CONTRIBUTING.md wins and this file is fixed.

Many sessions couldn't reach wowhead.com or warcraft.wiki.gg and used web search instead; the issues say which.

## The client

- Forever is client 1.60.1, interface `16001` (the TOC's `## Interface`), with the retail UI and the addon compartment. Source: #93 ([TOC format](https://warcraft.wiki.gg/wiki/TOC_format); Forever addons on CurseForge such as [Forever LazyChatButtons](https://www.curseforge.com/wow/addons/forever-lazychatbuttons)). Whether the compartment is there: **launch check** (#50).
- It uses the modern (12.x) API, with Midnight's addon restrictions. Source: [#32](https://github.com/CKozanecki/FriendlyForever/issues/32#issuecomment-6484071238) ([classicwowforever.com](https://classicwowforever.com/guides/wow-forever-addons-api-compatibility/), [Patch 12.0.0 planned API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes)); community sources, no blue post.
- Addons ship their own icons as TGA through `## IconTexture`; the game loads TGA and BLP reliably, not PNG. Source: #65, #93. How the icon looks: **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484272603)).

## Secret values

- In restricted moments the game hands addons **secret values**. Addon code must never compare, index, measure, concatenate or send one; it tests for them with `issecretvalue` and `issecrettable` (`Util.IsSecret`, `Util.Readable`). Source: #32 (Midnight's rules, sources above); CLAUDE.md's "Secret values".
- Chat received inside an instance can arrive as secret values. Source: #32. **Launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484203880), "Instances").
- Whether your own PvP flag, and other players' flags and names, are secret, and when: **launch check** (#50). Until then the addon reads them as possibly secret. Source: as built for #27 and #30 (`Offers.lua`, `GroupBuffs.lua`).
- Whether group members' roles and aura casters are readable: **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6459299223), from #68).

How the simulated client models secrets, and its limits, is in [simulated-client.md](simulated-client.md).

## Chat

- A chat message is at most 255 bytes (`Util.MAX_CHAT_BYTES`), and may not contain `|` escape codes. Source: as built since #20; the simulated client enforces both.
- Addons may use `/say` outdoors only right after a key press (a hardware event); inside instances they may use it freely. Source: [Patch 8.2.5 API changes](https://warcraft.wiki.gg/wiki/Patch_8.2.5/API_changes); as built (README's Buff thanks, `ChatQueue.lua`). **Launch check** (#50).
- Whether text emotes (`/thank`) also need a key press is unknown; the addon assumes they do. Source: #52 (PR #20). **Launch check** (#50).
- Whether `C_ChatInfo.PerformEmote("THANK", unit)` (with `DoEmote` as the fallback) is aimed at that unit. Source: #52. **Launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484955581)).
- The game has a chat lockdown (`C_ChatInfo.InChatMessagingLockdown`); nothing is sent while it's on. Source: #32. Whether it covers addon messages: **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484203880)).
- Raid join messages do appear on Forever: the maintainer saw them on the beta, 2026-10-22. Source: #15.

## Addon messages

From #32 ([research comment](https://github.com/CKozanecki/FriendlyForever/issues/32#issuecomment-6484071238); [SendAddonMessage](https://warcraft.wiki.gg/wiki/API_C_ChatInfo.SendAddonMessage), [Patch 10.2.7 API changes](https://warcraft.wiki.gg/wiki/Patch_10.2.7/API_changes), [Icy Veins: combat restrictions eased](https://www.icy-veins.com/wow/news/combat-addon-restrictions-eased-in-midnight/)). Every item here is a **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484203880)).

- Since 10.2.7, `C_ChatInfo.SendAddonMessage` is throttled per prefix: 10 messages, refilled at 1 a second. The server can change these numbers at any time (#32).
- A throttled send returns `Enum.SendAddonMessageResult.AddonMessageThrottle`; 0 means success (#32).
- A prefix is at most 16 characters, and a message at most 255 bytes (#32).
- Under Midnight's rules addons may not message other players inside instances (on live: boss encounters and Mythic+) (#32).
- Message types so far: `HELLO` (#32) and `ANSWER` (#37), whispered to a player whose favour you just returned, so their copy doesn't owe you one back. Whether an addon whisper reaches a stranger nearby decides whether `ANSWER` works at all; without it, buff back still stops after one round within its 10-minute window (#37). **Launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6504872140)).
- Unknown: the sender name's form in `CHAT_MSG_ADDON` (`First-Surname` or `First Surname`), and whether an addon whisper reaches a stranger nearby (#32).

## Names and races

- Every character has a first name and a surname (`Nikki-Shifts`), with no realms, and the game can't find a player by first name alone. Source: [Icy Veins: names in Forever](https://www.icy-veins.com/wow-forever/news/names-are-different-in-wow-forever-here-are-the-rules-and-the-official-look/); as built (README, `Util.lua`). How `/targetexact` spells a two-part name, and how `UNIT_SPELLCAST_SENT` gives the target: **launch check** (#50).
- Until a group member's details load (just after they join), the client can name them `UNKNOWNOBJECT` ("Unknown" in English), and the addon treats that as no readable name (`Util.UnitFullName`). Source: #99, found by the UI simulator (#83, PR #96); the default UI's `UNKNOWNOBJECT` global string. What Forever's `UnitName` returns then (with or without a surname, secret or not), and whether `UNIT_NAME_UPDATE` fires when it loads: **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6485285625)).
- There are 10 playable races: Classic's eight plus the two Skyborne peoples, High Order (Alliance) and Windshaper (Horde). Source: [#52](https://github.com/CKozanecki/FriendlyForever/issues/52#issuecomment-6484052636) ([Warcraft Tavern: races](https://www.warcrafttavern.com/forever/guides/races/), [seemeta](https://seemeta.com/en/wow-forever/races)).
- The Skyborne share one race file name; the addon tells them apart by race ID 95 (High Order) and 96 (Windshaper), with the faction as the fallback. Source: #52 (no external source for the IDs). **Launch check** (#50: the race and ID in `/friendly status`).

## Maps and capitals

From #34 ([research comment](https://github.com/CKozanecki/FriendlyForever/issues/34#issuecomment-6484024537); [C_Map.GetBestMapForUnit](https://warcraft.wiki.gg/wiki/API_C_Map.GetBestMapForUnit), [Warcraft Tavern: Skyborne](https://www.warcrafttavern.com/forever/guides/skyborne/), [Icy Veins: Skyborne](https://www.icy-veins.com/wow-forever/news/all-skyborne-official-info-customization-druid-forms-zones-classes-abilities-and-more/)).

- Forever's map numbering isn't published. The addon uses Classic Era's map IDs: Stormwind 1453, Orgrimmar 1454, Ironforge 1455, Thunder Bluff 1456, Darnassus 1457, Undercity 1458 (retail's would be 84, 85, 87, 88, 89, 90) (#34). **Launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484459777)).
- The Skyborne have one hub, Valanaar on Zephras Isle, shared by High Order and Windshaper; guides disagree on whether it's a capital. A skyship runs from it to Dalaran, which the owner confirms is an Alliance city on Forever. Both count as capitals ([owner's decision on #34](https://github.com/CKozanecki/FriendlyForever/issues/34#issuecomment-6484459000)). Their map IDs: **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484459777)).
- Whether entering a city fires `ZONE_CHANGED_NEW_AREA` (#34): **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484459777)).

## Buffs

From #68 (beta build 70425, mid-October 2026; [Paladin deep dive](https://www.wowhead.com/forever/blue-tracker/news/eu/world-of-warcraft-forever-class-deep-dives-paladin-world-of-warcraft-blizzard-24302099), [Blessing of Salvation (Forever)](https://www.wowhead.com/forever/spell=1038/blessing-of-salvation), [paladin talent calculator](https://www.wowhead.com/forever/talent-calc/paladin), [forg.gg build 70425](https://forg.gg/en/forever/tips/build-70425)). These are beta sources, confirmed against the live client at launch ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6459299223)).

- **Blessings last 1 hour,** up from 5 or 15 minutes (#68).
- **Salvation isn't a Blessing:** a member can wear your Salvation and one of your Blessings. Salvation (spell 1038) cuts the target's threat by 30% for 1 hour, on a party or raid member; it's learned at level 26 (#68).
- **Mass Salvation** (formerly Greater Blessing of Salvation) covers every member of the target's class in the group; learned at level 60, it uses a Symbol of Kings. The addon uses Classic's ID, 25895 (#68).
- **Revoke** is new at level 26: it takes Salvation or Mass Salvation off a party or raid member (instant, 40 yards, no cooldown). Its spell ID isn't known, so the addon finds it by its English name, and doesn't offer it in other languages (#68, #74).
- **Launch checks** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6459299223)): the Salvation, Mass Salvation and Revoke IDs; whether Revoke takes off another paladin's Salvation; which role APIs exist (`UnitGroupRolesAssigned` or `GetPartyAssignment("MAINTANK", unit)`) (#68).
- The buff spell IDs in `BuffData.lua` are Classic Era's (1.15); Forever's may differ. Source: as built for #27. **Launch check** (#50).
- **Unending Breath** (warlock, 5697) has no group version. Spell 131 is the **shaman's** Water Breathing, which also lets the target breathe underwater, so `BuffData` lists it as a blocker (wearing it counts as having Unending Breath), not as a group version a warlock could cast. Source: [#135](https://github.com/CKozanecki/FriendlyForever/issues/135) ([Unending Breath](https://warcraft.wiki.gg/wiki/Unending_Breath), [Water Breathing](https://warcraft.wiki.gg/wiki/Water_Breathing), [classicdb 5697](https://classicdb.ch/?spell=5697), [classicdb 131](https://classicdb.ch/?spell=131)); Classic sources, as wowhead.com couldn't be reached. Both IDs, whether shamans have Water Breathing on Forever, and whether Forever adds a group water-breathing spell (it has an underwater dungeon; [owner on #135](https://github.com/CKozanecki/FriendlyForever/issues/135#issuecomment-6505287339)): **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6505345638)).
- Unit power is secret for strangers, so the addon decides who uses mana by class. Source: as built for #27 (`BuffData.MANA_CLASSES`). **Launch check** (#50).
- Buff back remembers every buff of yours the game says reached a player, cast by hand too (#37). It relies on `UNIT_SPELLCAST_SENT` firing for every cast of yours with the target's name and a `castGUID`, and on `UNIT_SPELLCAST_SUCCEEDED` giving the same `castGUID`, as in the retail API ([UNIT_SPELLCAST_SENT](https://warcraft.wiki.gg/wiki/UNIT_SPELLCAST_SENT)). Whether the name is the first name alone, or "First Surname", and whether a refreshed buff arrives as a new aura (`addedAuras`): **launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6504872140)).
- Whether group members' aura caster (`sourceUnit`) is readable, whether `C_Spell.IsSpellInRange` or `IsSpellInRange` answer for them, and the exact "Out of range" and line-of-sight error texts: **launch check** (#50, from #30).

## Battlegrounds

From #71 ([research comment](https://github.com/CKozanecki/FriendlyForever/issues/71#issuecomment-6482177856); the [Forever beta development notes](https://us.forums.blizzard.com/en/wow/t/2360696) don't mention battlegrounds).

- In a battleground, `IsInInstance()` says `"pvp"`. Forever may not use the instance group category for battlegrounds, so the addon checks the zone type too (#71).
- How Forever shows the preparation phase is unknown: the Preparation aura (Classic's 44521), `START_TIMER` with `TIMER_TYPE_PVP` (1) or `Enum.StartTimerType.PvPBeginTimer` (0), both or neither. `GetBattlefieldWinner()` is nil until the end. Whether a resurrection gives a Preparation aura again is unknown too (#71). All **launch checks** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6482739382)).

## Interface

- A macro's conditions (`[help,nodead]`) apply to the unit the cast goes to. Source: #84. **Launch check** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6484117926)).
- Which half of a key press acts (`ActionButtonUseKeyDown`), whether `/targetlasttarget` works after `/cleartarget`, whether "Out of range" fires `UNIT_SPELLCAST_FAILED` or only `UI_ERROR_MESSAGE`, and #28's override bindings (the scroll wheel as the lent key; changes in `PLAYER_REGEN_DISABLED`): **launch checks** (#50).
- Text widths and cut-off text, the button's hint and tooltip, and the message boxes' alignment: **launch checks** ([#50](https://github.com/CKozanecki/FriendlyForever/issues/50#issuecomment-6482691888), from #64 and #85).
