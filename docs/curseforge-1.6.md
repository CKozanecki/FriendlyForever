<!-- The CurseForge description for 1.6, for the owner to paste. It isn't shipped: docs/ is in .pkgmeta's ignore list.
     Paste it with CurseForge's editor set to Markdown. Every list needs a blank line before it, or CurseForge loses the formatting (#522).
     It describes what the addon does. It never carries patch notes, "New in" lists or version history: the changelog has those.
     Update it only when a feature is added or changes (CONTRIBUTING.md's Releasing section). -->
## Description

Friendly Forever makes you the friendliest adventurer in WoW Forever: it greets, welcomes and thanks for you, and returns every kindness with a buff. It's built to stay friendly when a whole guild runs it, without flooding chat.

## Getting started

- **Start here:** the first options page shows what the addon does, your main settings and keys, and a link to every other page.
- **A short walkthrough:** on a new install, a step-by-step tour of buff order, buff mode's key and triggers, and your thanks and welcome lines. Finish or skip it to switch the addon on, and replay it any time from Start here. After an update, What's new shows only the new steps.
- **Find any setting:** `/friendly find <word>` (for example `/friendly find snooze`) says which page each matching setting is on.

## Greetings and thanks

- **Guild greetings:** says hello when guildmates log in, and welcomes new members to the guild. When a line names a zone, it's your guildmate's.
- **The Guild page:** every guildmate with the addon sees who has it (version, last seen), who leads, the guild's limits and the vetoed lines. The guild master picks which ranks lead; leaders cap how many copies greet a login or welcome a new member, turn guild hellos off for the whole guild, and veto a line so no copy says it again. Limits only ever make the addon quieter: your own lower setting stays, and nothing a guildmate sends can make your copy cast or say new words.
- **Group welcomes:** says hello when you join a party or raid, with a different line when you rejoin the same group.
- **Level-up cheers:** congratulates a party member who levels up.
- **Thanks for buffs:** thanks whoever buffs you, by name and buff, with a line in /say, a whisper, a /thank emote, or a line and an emote. You choose what happens when it can't reach them.
- **See what a line will say:** hover any message box to see three examples, every phrase each placeholder ({greeting}, {thanks}, {blessing}, {cheer}) can pick, and what {zone}, {timeofday} and {myclass} read now.
- **Flavour lines:** 30 editable lines per message, in a Warcraft fantasy voice. They change with your race, faction, zone and the time of day ("Throm-ka, Thrall! Strength and honor."). Every Forever race has its own voice, including the High Order and Windshaper Skyborne.

## Favours

One tab holds all of it: thanking players who buff you, offering your buff back, buff requests, passers-by and the buff button, with two sets of 30 editable lines, **Thank-you lines** and **When my buff lands**.

- **Return the favour:** when a stranger buffs you, a button offers your buff back. One key press or click casts it on them and gives you your own target back.
- **Picks the right buff:** your buffs in the order you choose, never one they already have or their class can't use. A buff of yours that's wearing thin on them is renewed. It casts the highest rank their level allows, and says so when it steps down.
- **The Buffs tab:** each character's own buff order, with each buff's icon, and Never offer, on one tab. For every buff you choose who gets it in each place: Strangers (players outside your group who buff you), Party, Raid and PvP. Choose by role (Tanks, Healers, Damage), by class or Everyone, add names that always or never get it, or turn it Off.
- **Knows who buffed you:** when the game can't name a stranger who buffed you, their copy of Friendly Forever quietly tells yours, so you can thank them by name.
- **Buff requests in chat (off by default):** when someone whispers you, or says in /say or party chat, "mark pls", "int please" or "can I get fort?", they go on the button with the buff they asked for. It only counts your own class's buffs, by name or common nickname, and nothing is said back.
- **Passers-by (off by default):** in buff mode, in the open world, the button can also offer your buffs to players nearby who aren't in your group, one buff per press, after everything else you owe, and never a word in chat. Never in a dungeon, raid, battleground, arena, capital city or fight, and never someone flagged for PvP while you aren't. Right-click skips someone for 10 minutes. It needs friendly nameplates, and tells you why when it can't run.
- **A line once it lands:** optionally say a line once the game confirms your buff reached them (off by default).
- **Favour ledger:** who buffed you, whether you thanked them and buffed them back, with titles from Courteous to Friend to All Azeroth.

**Safe by design:**

- never flags you for PvP;
- never casts on the dead or on someone else;
- nothing is ever cast without your press;
- your ignore list always applies.

## Buff mode

- **Lend it a key:** lend the button a key of your choice, the mouse wheel by default, and buff a whole raid by scrolling. The key is lent only while buff mode is on and goes back to normal when it ends, and during fights. Shift-click the minimap button to turn buff mode on or off. Both keys also have a Friendly Forever section in Key Bindings.
- **Buffs your group:** fills in party and raid members missing your buffs, one per press, skipping anyone dead, out of range, out of sight or flagged for PvP. Group versions (Arcane Brilliance, Prayers, Gift of the Wild, Greater Blessings) are used when they cover enough of the group.
- **Buffs you, too:** solo, it keeps your own Fortitude, Intellect, Mark or Blessing up, and turns itself on when one is missing or running low.
- **Your self-buffs:** Inner Fire, mage and warlock armors, Lightning Shield, Battle Shout, Aspects, Trueshot Aura, paladin auras and Righteous Fury, after everyone else is done.
- **Weapon buffs (experimental, off by default):** pick a stone, oil, poison or shaman imbue for each hand on the Weapon buffs page. Once everyone else is done, the button offers it for a hand with nothing on it, and one press puts it on. While you're resting in a city, an inn or a town, weapon buffs wait until you leave.
- **Druid forms and Ghost Wolf:** in a druid form (except Moonkin, which casts as usual) or Ghost Wolf, the key leaves your buffs alone so scrolling never knocks you out of the form; a click still casts. Turn on **Fast-cast buffs in form** to let the key cast them too, and the button offers your form back once everyone is buffed.
- **Tops up before it runs out:** a buff of yours with under 5 minutes left (you choose) counts as missing, so you renew it in time.
- **Shares the work in raids:** copies of Friendly Forever split the buffs between them, so three priests give Fortitude, Spirit and Shadow Protection between them, and paladins split their Blessings instead of all giving Kings.
- **Raid assignments (experimental):** the raid leader and assistants can assign a buff to a player for chosen groups with `/friendly raid`. Copies offer an assigned buff only to its groups; anything unassigned, or an assignment that can't be met, keeps the automatic split. An assignment can only narrow what your copy offers, never cast.
- **Paladin-aware:** gives one Blessing each, never overwriting yours.
- **Even underwater breathing:** offers Unending Breath or Water Breathing only near water, so you're never asked to cast them in the desert.
- **Dungeons and raids:** turns on as you enter with your group and stays on until everyone is in and buffed, or the first pull.
- **Battlegrounds and arenas:** every buff starts off in PvP; turn on the ones you want on the Buffs tab's PvP place. Once the gates open, the addon goes quiet for the rest of the battle.

**Turns itself on and off:**

- **On** when you join a group, when someone in your group is missing your buffs, when one of your own buffs is missing or low (solo too), after a death between pulls, when someone buffs you, or at a campfire.
- **Off** again at the first pull, once everyone's buffed, or after a timeout.

## Friendly, not spammy

When a whole guild runs Friendly Forever, it should feel warm, not noisy:

- **Quiet coordination:** addon users coordinate over a hidden addon channel that never appears in chat.
- **One thanks each way:** one combined thank-you per exchange, after the last buff, and buff trades stop after one round.
- **Varied hellos:** when a guildmate logs in, hellos come a few seconds apart, with different lines, and from at most 5 of you (you choose, 1 to 20). Someone who logs straight back in isn't greeted twice.
- **Sensible welcomes:** in raids only the leader says the welcome; in 5-player groups, everyone may.
- **City quiet mode:** in capital cities, with hundreds of players around, it stays quiet and the buff button is hidden by default.
- **Rate limits:** cooldowns per player and per group, and at most 4 lines a minute in each chat by default.
- **Silent group thanks:** buffs inside your group are never thanked out loud.

## Control and safety

- **One options panel:** every message type has its own tab, with on/off, delays, cooldowns and lines; plus snooze, an ignore list, profiles that follow the character, and export/import of your settings as one line of text.
- **Each character its own:** buff order, weapon buffs, buff mode's key and who gets each buff are set per character, so a priest and a druid never share them.
- **Easy to read:** one colour palette chosen to read well on the game's dark backgrounds and with colour blindness, and "on" and "off" are always spelled out.
- **Stays out of the way:** respects AFK, the game's chat lockdown and combat. Settings are checked on load and repaired if damaged.
- **Safe with untrusted input:** never runs text as code, and other players can't control it. A buff request, a passer-by, a guild leader or a raid leader can only narrow or quiet what your copy does; you still press every cast.

## Updating

After an update that adds files, fully restart the game: /reload isn't enough. The changelog says when.

_In active development for WoW Forever. See the changelog for what's in each release._
