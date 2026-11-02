# Friendly Forever: launch-day runbook (Wed Nov 4)

Built from #50's checklist and comments (every launch check, plus the approved CurseForge screenshot list), the release steps in CONTRIBUTING.md, and the README. Ordered by what each check needs, so you set things up once: solo first, then one other player, then a group, then the guild.

Legend: **[S]** = a screenshot to take at that moment (the CurseForge list from #50). **→ #n** = the issue to note the answer on.

---

## 0. Before you log in

- [ ] Install the **0.9.1** build (the CurseForge file, tag `v0.9.1`; `main` has no addon changes since). **Fully restart the game**; a new file isn't seen after `/reload`.
- [ ] **Do NOT touch `FriendlyForeverDB` yet.** The first-run walkthrough only fires when there are no saved settings, so check it first (section 1) before you configure anything. The settings are **account-wide**: `WTF/Account/<ACCOUNT>/SavedVariables/FriendlyForever.lua`, shared by every character, so a second character is not a fresh install. To test first run, move that file aside (with the game closed). A true first run says "welcome! Friendly Forever is off until you finish or skip its walkthrough" and starts off. Once the walkthrough has been finished or skipped, the settings file remembers it: another character on the account sees nothing, and the addon stays as you left it. Only settings saved before the walkthrough existed get the "new: a short walkthrough…" line and one showing.
- [ ] Turn on Lua errors: `/console scriptErrors 1` (or BugSack). Any error at any point is a finding.
- [ ] Turn on `/friendly debug`, but only after section 1, since debug adds chat noise to the first-run shots.
- [ ] Screenshot hygiene: native resolution, default UI scale, no other UI addons visible, nothing private in chat. Save originals uncropped.
- [ ] Helpers lined up: a second character or friend running the addon (section 4), two or three guildmates (section 7), and a way to reach a paladin, a warlock or shaman, and a priest or druid (section 8).
- [ ] Keep a scratch file open to paste `/friendly status` output and any `/dump` results into. Everything you learn is a fact for `docs/forever-facts.md` later.

## 1. First run on a fresh install (once only)

- [ ] Addon starts **off**. The walkthrough opens at login, with a chat line pointing to Start here. **[S]** the walkthrough step by step (also gives you Options shots).
- [ ] Walkthrough window is opaque, sits above the options window, clears the action bars, can be dragged; X skips it.
- [ ] Each step opens its page; the triggers step scrolls Buff Back so "Buff mode turns on by itself" is near the top.
- [ ] Pull a mob mid-walkthrough: it closes, then returns at the same step after the fight.
- [ ] **Finish** (or Skip) turns the addon on.
- [ ] Esc > Options > AddOns > Friendly Forever: **Start here** is the first page, notes wrap, the area scrolls, and it shows the buff-back key from Key Bindings.

## 2. Solo smoke: client API facts (no other players needed)

Run `/friendly status` first and paste it into your scratch file.

- [ ] **Skyborne race and race ID** appear in `/friendly status` (High Order 95, Windshaper 96). → #50
- [ ] **Addon compartment exists**, and the icon shows in all three places: minimap button (round, no square corners), compartment, AddOns list at character select. Greys out when the addon is off. **[S]** minimap button + hover tooltip, compartment entry, optionally the AddOns list.
- [ ] **Settings search** (#48): does Esc > Options have a search box? Is there a **Find a setting** page? Does searching `snooze`, `nameplate`, `buff` find headings? Fallback `/friendly find snooze` prints "Snooze: on the General page". If the page is missing: `/friendly debug`, `/reload`, look for `settings search page: not made: …` (the API exists but failed). **No such line at all** means the client doesn't have `Settings.RegisterVerticalLayoutSubcategory` or `CreateSettingsListSectionHeaderInitializer`, which is the likelier reason; note that.
- [ ] **Combat event timing:** run this once, then pull a mob. → #50, #100
  `/run local f=CreateFrame("Frame") f:RegisterEvent("PLAYER_REGEN_DISABLED") f:SetScript("OnEvent",function() print("REGEN_DISABLED, lockdown:", InCombatLockdown()) end)`
  (`false` = what we assume; `true` = scenarios' assumption should change.)
- [ ] **UI scale / canvas:** default UI scale at 1920×1080 (and 2560×1440 if you can); is the canvas 768 units tall like retail? Note the buff-back button's default position.
- [ ] **Emote:** with How to thank set to the emote, get buffed by someone (or do this in section 4) and press a key: chat should read "You thank Bob.", not "You thank everyone."
- [ ] **Copy window:** `/friendly export`, then `/friendly report`: text pre-selected, Ctrl+C works, long line wraps and scrolls, paste into `/friendly import` reads it, Esc and the close button both close. In `/friendly import`, the hint's second line ends above the paste box with a gap.
- [ ] **Options layout, every tab:** tabs span the full panel width on open; Buff Back's description wraps onto 2–3 lines without overlapping the Enabled row; message boxes' text is left-aligned (simulator draws it centred); the "Stay quiet in capital cities" row (Buff Thanks) and "Show the button in capital cities" row (Buff Back) sit on their own rows with labels inside the panel.
- [ ] **Palette:** `/friendly off`, `/friendly on`, `/friendly status`, `/friendly debug` read clearly over a bright zone and a dark one (gold name, sky-blue on/enabled, rose off/disabled, orange notes, grey-blue hints). Minimap tooltip: Enabled blue, Snoozed orange, Disabled rose. Options hints grey-blue; nameplate warning orange.
- [ ] **Capital cities:** in each capital, `/friendly status` shows the map ID in its "capital city" line. Compare with `Cities.CAPITALS`: table has Classic IDs 1453–1458 (Stormwind 1453, Orgrimmar 1454, Ironforge 1455, Thunder Bluff 1456, Darnassus 1457, Undercity 1458); retail's would be 84/85/87/88/89/90. Also record **Valanaar** and **Dalaran** (not in the table yet). Check entering each fires `ZONE_CHANGED_NEW_AREA`. → #34 / #50 *(fix needed if IDs differ)*
- [ ] **Water:** `IsSwimming()` / `IsSubmerged()` exist; `/friendly status` "near water" says "in the water" when swimming. Which slot of `GetMirrorTimerInfo(1..3)` is `"BREATH"` (sim assumes 2); `MIRROR_TIMER_START/STOP` fire.
- [ ] **Chat lockdown / `/say` rules:** `/say` outdoors works only on a key press (hardware event)? Does an emote need a key press too?

**[S] Options pages** (Esc > Options > AddOns, or `/friendly`; seed some state first by playing):
General (snooze buttons, chat limit, ignore list with a name in it, profiles, Export/Import, Copy for a bug report) · Messages: Buff Thanks (how to thank, 30 lines, timing rows; nameplate warning + "Show friendly player names" button if nameplates are off; Thank them with / If that can't reach them) · Messages: Buff Back (buff order, a Who rule, buff mode key, auto on/off rows) · one of Guild Login/Party Join · Favour Ledger (thanked, returned, one with a reason it wasn't thanked, totals, a title) · Export window (optional).

## 3. Chat outputs to capture along the way

Get these as they happen naturally; don't force them.

- [ ] **[S]** a buff thank-you in /say to a named stranger, in your race's voice
- [ ] **[S]** a guild login greeting; a welcome to a new guild member if one happens
- [ ] **[S]** a party join welcome and a "hello" on joining someone's group
- [ ] **[S]** the buff-back line said after your buff lands (if on)
- [ ] **[S]** a `/thank` emote thank-you, and the "friend" fallback
- [ ] README extras (not for CurseForge): `/friendly status` and `/friendly buffback` output

## 4. With one other player running the addon (not grouped, ideally a stranger-like setup)

Both with `/friendly debug` on. Do this on a quiet street outside a capital, out of combat.

**Addon messages**
- [ ] **A whisper reaches a stranger nearby.** One-off hello: `/run C_ChatInfo.SendAddonMessage("FriendlyFvr","1;HELLO;<Your-Name>;0.9.1;1","WHISPER","<Their-Name>")`. Other side's `/friendly status` should count 1 received and show 1 other copy seen on both sides. **This is the decision point for ANSWER, PLAN and RECEIPT**, so do it early.
- [ ] **Sender name form** in `CHAT_MSG_ADDON`: `First-Surname` or `First Surname` (a form the addon can't parse is dropped as "malformed"; a **first name alone** is dropped as spoofed, which also looks like messages never arriving: `/friendly status` counts it under "N spoofed" in its "addon messages dropped" line, and the debug log reads "dropped a message from First: says it is about First-Surname"; a rising "spoofed" or "malformed" count is the name-form answer, not a forgery).
- [ ] `C_ChatInfo.SendAddonMessage` returns `Enum.SendAddonMessageResult` (0 = success). If nothing is returned, every send shows "not sent" in status even though it went out.
- [ ] Throttle still 10 per prefix, 1/s refill (addon stays at half).
- [ ] `/chatlist` shows only General, Trade, LocalDefense. No new channel joined.

**Buff back (the macro: `/cleartarget`, `/targetexact First Surname`, `/cast [help,nodead] <buff>`, `/targetlasttarget`)**
- [ ] Other player buffs you; the button shows their name and the buff you'll give back. **[S]** the offer (a friendly nameplate over them if possible).
- [ ] How `/targetexact` must spell a two-part name; does it work with the surname form the addon sends?
- [ ] `[help,nodead]` works: press for someone who just died or went hostile; nothing is cast and nothing lands on anyone nearby.
- [ ] `/targetlasttarget` after `/cleartarget` brings your old target back.
- [ ] **Which half of a press acts** (key down or up), for keys and mouse clicks.
- [ ] Press it; **[S]** the feedback line "Returned Mark of the Wild to …".
- [ ] `UNIT_SPELLCAST_SENT` reports what as the target ("First", "First Surname", "First-Surname") and gives a `castGUID`; `UNIT_SPELLCAST_SUCCEEDED` follows with the same one.
- [ ] "Out of range" refusal: does it fire `UNIT_SPELLCAST_FAILED` or only `UI_ERROR_MESSAGE`, and how soon after the press does the error text arrive?
- [ ] Long text: pick a long favour (priest + "missing your Power Word: Fortitude"): name and favour lines stay inside the button on one line, cut with "…". Tooltip shows the full line. `/friendly move` hint "Drag, then /friendly move" fits whole. **[S]** moving the button (optional).
- [ ] Whether PvP flags and other players' flags/names are **secret**, and when.

**Exchanges and receipts**
- [ ] **Hand casts are reported:** cast a buff by hand on them; SENT fires with name + castGUID, SUCCEEDED follows.
- [ ] **ANSWER:** return their favour while both run the addon. Their `/friendly status` counts one more received, and they aren't offered a buff back for yours.
- [ ] **PLAN:** trade buffs; log shows "…'s copy plans: …".
- [ ] **Global cooldown / one thank-you:** buff them three times by hand; their single thank-you lists all three.
- [ ] **Refreshed buff:** when someone recasts a buff you already wear from them, does `UNIT_AURA` list it in `addedAuras` or only `updatedAuraInstanceIDs`?
- [ ] **RECEIPT:** with them off your nameplates and untargeted, their debug log says "named by their copy's receipt"; status counts it received. Is the caster really unreadable for strangers (secret `sourceUnit`)? If the game names them anyway, receipts change nothing.

## 5. Capital quiet-mode checks

- [ ] No thank-yous in a capital; the ledger still counts them. Button hidden in a capital unless "Show the button in capital cities" is ticked; shows your favours once you leave. Buff mode turned on in a city works as usual.

## 6. In a party (2+ others)

- [ ] **Buff mode** (`/friendly buffmode on`): button shows "Buff mode: Mouse Wheel Up" above it and offers a member missing your buff. **[S]**
- [ ] **[S]** buff mode with nothing to do (everyone has your buffs); button says so.
- [ ] Mouse wheel works as the lent key (each notch = one press); the wheel zooms again when buff mode ends **and during a fight**.
- [ ] Buff mode buffs each member in turn. `C_Spell.IsSpellInRange` (or `IsSpellInRange`) answers for group members; note the exact "Out of range" and line-of-sight error texts.
- [ ] **Roles:** which of `UnitGroupRolesAssigned` / `GetPartyAssignment("MAINTANK", unit)` exist; are roles and aura casters readable or secret?
- [ ] Group members' aura `sourceUnit` readable (needed for Blessings)?
- [ ] **Unknown names:** form a group with someone far away or just logging in; `/run print(UnitName("party1"))` right away and again once they show. Is it `UNKNOWNOBJECT`? Surname with it? Secret? Does `UNIT_NAME_UPDATE` fire?
- [ ] **Top-up** (#42): a member wearing your buff in its last 5 minutes is offered it again. If never: `/dump C_UnitAuras.GetAuraDataByIndex("party1",1,"HELPFUL")`; are `expirationTime` and `duration` present, numbers or secret? `expirationTime` on `GetTime()`'s clock, 0 for permanent. Recast refreshes with no "more powerful spell" error. Repeat after a pull and inside an instance (secret there is fine).
- [ ] Turn-on triggers: joining a group, a death in the group **after the group's first pull** (not before), a stranger's buff (outside a city), each switch on/off. First pull ends it, everyone-buffed ends it, timeout ends it.

## 7. Guild (3+ guildmates running the addon)

- [ ] Set **Most players… who greet one login** to 1 or 2 and `/friendly debug` on. Have someone log out and in.
- [ ] Read each copy's debug log by whether it announced. **A copy that heard K other copies' GREETs before its own turn** never announces and logs only "not sending for …: N other copies already greet them (most: K)" (the cap working). **A copy that announced** logs "announced greeting …", then one of: "greeting …: N other copies announced first" (it greets); "not sending for …: N other copies announced first (most: K)" (the cap, after its own echo came back); "greeting … with the random wait only: no announcement of mine has come back yet"; or "not sending for …: my announcement never came back".
- [ ] "…no announcement of mine has come back yet" means no echo of yours was **recognised**: either the game doesn't send your guild addon messages back, or it names you differently. Before you record "no echo", check `/friendly status` and that the "spoofed" and "malformed" counts in its "addon messages dropped" line didn't rise (a first name alone counts as spoofed). Such a copy greets 15 s (`GuildHellos.ECHO_WAIT`) after its "announced" line; other copies' GREETs still count, so the cap mostly holds, unless the game names other copies differently too. "…my announcement never came back" is the opposite case: echoes do work, but this one `GREET` was lost or came back more than 15 s late, and that copy stayed silent. Nothing breaks either way. Record which lines you saw on #50 and #38.
- [ ] At most K hellos, each a different line, a few seconds apart (15 s or more after the "announced" line if your own echo isn't coming back). Inside an instance: greets after the random wait with "…random wait only: inside an instance".
- [ ] Order and delivery: everyone sees the same order (can't be fully proven; note anything odd).

## 8. Class-specific

- [ ] **Paladin:** Salvation spell ID (1038?) and Mass Salvation (25895?); is Salvation separate from the Blessing; **Revoke's spell ID** (`/dump C_Spell.GetSpellInfo("Revoke")`; nil for a paladin who hasn't learned it); does Revoke remove **another paladin's** Salvation? Revoke offered correctly in buff mode. **[S]** the Buff Back tab as a paladin (Revoke Salvation, "Blessings I give in this raid" in a raid).
- [ ] **Warlock/shaman water:** `/run print(C_Spell.GetSpellName(5697), C_Spell.GetSpellName(131))` → `Unending Breath Water Breathing`. Cast Unending Breath on a member in buff mode; the button moves on. Not offered on dry land, offered while swimming, stays offered 2 minutes after. Any group water-breathing spell on Forever?
- [ ] **Drowned City:** instance ID (`select(8, GetInstanceInfo())`), exact name "The Drowned City", type `"party"`. **Blackfathom Deeps** ID (Classic's 48).
- [ ] **Buff spell IDs in `BuffData.lua`** (Classic's) match Forever's for your classes.
- [ ] **Instances:** addon messages refused (which code)? Incoming text/sender readable? `C_ChatInfo.InChatMessagingLockdown()` says so? No RECEIPT sent inside any instance (status "sent" unchanged).

## 9. Battleground (if you can queue one)

- [ ] Preparation aura shown (Classic ID 44521?) and gone when gates open; `START_TIMER` fires, which type; `timeRemaining` in seconds. `GetBattlefieldWinner()` nil during, set after. Resurrection doesn't reopen prep.
- [ ] If neither prep signal exists, the addon just stays quiet, which is the safe side.

---

## 10. After the game session: triage

Sort every finding into one of three buckets:

| Bucket | Examples | Action |
| --- | --- | --- |
| **Data fix** | wrong map IDs (`Cities.lua`), spell IDs (`BuffData.lua`), Revoke ID, Drowned City / BFD IDs, `/targetexact` spelling | small PR each; needs both review loops before ready |
| **Behaviour fix** | an assumption was wrong and the addon misbehaves | PR with a test that reproduces it (red first) |
| **Just record** | it works as assumed | tick it off, move the fact into `docs/forever-facts.md` |

Then, in order:
- [ ] Merge the fixes. **Stop here and check `git log`:** version tags can't be moved or deleted once pushed.
- [ ] Update the "not tested" wording now that it is: `README.md` lines ~118, ~156, ~163 (capital IDs "known at launch", Revoke "found by its English name", "Not yet tested in WoW Forever"); the "launch check" notes in `docs/forever-facts.md`; the "isn't known yet" comments in `Cities.lua`, `BuffData.lua`, `Water.lua` if you now have the IDs; the `(not known yet)` label in Options is runtime, so leave it.
- [ ] Add CurseForge screenshots (Media tab) from the **[S]** list; crop copies, originals kept.

## 11. Publish 1.0.0

From CONTRIBUTING.md "Releasing":
1. PR: bump `## Version` in `FriendlyForever.toc` to `1.0.0`; rename `### Unreleased` at the top of `CHANGELOG.md` to `## 1.0.0` (tests check they agree) and fold in anything missing, including the launch-day fixes. `make release-notes` previews what CurseForge will show. Both review loops, `make check`, CI green. You merge.
2. Tag the merge commit and push **only that tag** (not `--tags`):
```bash
git tag v1.0.0 && git push origin v1.0.0
```
3. Release workflow: `verify` (tag on `main`, matches TOC, lint + tests, no secrets), then `release` waits for your approval in the `release` environment and uploads. Green job = done.
4. Verify the file landed on CurseForge with the 1.0.0 notes, and the GitHub release has the zip.
5. Close #50 (or move any still-unanswered checks to a follow-up) and record answers on #32, #34, #38, #100 as the checks asked.
