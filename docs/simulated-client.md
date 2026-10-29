# The simulated client

How `spec/support/wow.lua` models the game for the busted specs, and how to extend it. The rules for tests themselves (which kind each criterion needs, chaos-test invariants, mutation checks) are in [CONTRIBUTING.md](../CONTRIBUTING.md#specs-and-traceability) and [CLAUDE.md](../CLAUDE.md#tests); this file only describes the tool. Where the two differ, CONTRIBUTING.md wins and this file is fixed.

**Source:** everything here describes `spec/support/wow.lua` itself; read it when this file and the code differ, and fix this file. Game facts the model is built on are in [forever-facts.md](forever-facts.md), and the guesses it makes are listed in its ASSUMPTIONS block, with their launch checks on #50.

## What it is

A small simulation of the WoW client API, enough to load the addon as the game does and drive it with events. It is not the game: every behaviour it adds is a claim about WoW Forever, and claims that can't be checked before launch are listed as launch checks on #50.

- **Loading:** `wow.load()` reads `FriendlyForever.toc` and runs each listed file in order with the `(addonName, ns)` varargs, as the game does. `wow.parseToc()` returns the TOC's metadata and file list.
- **Booting:** `wow.boot(opts)` resets the client, loads the addon, fires `ADDON_LOADED` and `PLAYER_ENTERING_WORLD`, and advances past the login grace period. Options:
  - `opts.db`: the saved variables to start with;
  - `opts.before(state)`: change the client's state before the addon loads;
  - `opts.noGrace`: stop right after login;
  - `opts.autoBuffMode`: keep buff mode's turn-on triggers at their defaults (on, #72). Without it, boot turns them off unless `opts.db` sets them, so specs that join groups or get buffed don't lend a key by accident;
  - `opts.shippedLines`: keep the shipped message lines. Without it, types still on the shipped defaults use the fixed casual lines, since most specs check behaviour rather than wording.
- **State:** `wow.reset()` builds `wow.state` (guild, group, instance, lockdown, combat, units, auras, spells, CVars, clock) and the record tables tests check against:
  - `wow.sent`: chat lines the game accepted; `wow.blocked`: lines it refused;
  - `wow.casts`, `wow.keyActions`, `wow.printed`, `wow.timers`;
  - `wow.flaggedBy` and `wow.flaggedElsewhere`: players whose PvP flag a cast of yours caught (#76);
  - `wow.addonSent`: addon messages the game accepted; `wow.addonRefused`: those it refused, each with its result code; `wow.addonPrefixes`: the prefixes registered (#32).

Chaos tests work out their invariants from these records and from `wow.state`, never by calling the code under test (#73).

## Restrictions it enforces

These mirror real restrictions the addon must live with. Each one makes the client stricter, never looser.

- **Chat** (`SendChatMessage`): text must be a string of at most 255 bytes with no `|`; a whisper needs a target. In chat lockdown (`state.lockdown`) every line is blocked. Outside instances, `/say` and `/yell` need a hardware event (a key press), and text emotes do too.
- **Secret values:** `wow.secret(v)` makes a value that raises an error when addon code indexes, compares, measures or does arithmetic on it, and `issecretvalue` recognises it. Lua 5.1 can't make `if secret then` error, or intercept `#` on a table, so specs check that the code never acts on a secret. Units read as secrets while `state.unitsRestricted` is set, or per field with `unit.secrets = { name = true, ... }`; `wow.lockedAura(id)` is a secret aura whose `auraInstanceID` stays readable. Reading auras raises an error while `state.aurasRestricted` is set.
- **Secure buttons and combat:** protected frame changes and override bindings are refused in combat (`wow.enterCombat()`, `wow.leaveCombat()`), as they are in the game, except in `PLAYER_REGEN_DISABLED`'s handlers. Casts happen only through a key press or click on a secure button (`wow.pressKey`, `wow.press`), and a macro's conditions such as `[help,nodead]` are checked against your target before anything is cast.
- **Addon messages** (#32): `C_ChatInfo.RegisterAddonMessagePrefix` and `SendAddonMessage` answer with the 10.2.7+ result codes (`Enum.SendAddonMessageResult`, `Enum.RegisterAddonMessagePrefixResult`). The client refuses:
  - a prefix over 16 characters;
  - a message over 255 bytes;
  - a route you aren't in;
  - a whisper with no target;
  - anything during lockdown or while `state.addonBlocked` is set (an instance under Midnight's rules).

  The game's throttle applies per prefix: 10 at once, then one a second (`wow.ADDON_BURST`, `wow.ADDON_REFILL`). A chaos test can therefore check that the addon never reaches it. `state.noAddonMessages` makes a client without the API.
- **Spells by name:** `C_Spell.GetSpellInfo(name)` and `GetSpellTexture(name)` answer only for spells you know, since the game's name lookup goes through your spellbook; by ID they answer for any spell.

## The ASSUMPTIONS block

The block headed `ASSUMPTIONS ABOUT WOW FOREVER` near the top of `wow.lua` lists every behaviour that is a guess rather than a known fact. Each is a `state` setting where possible, so specs can try the alternatives. Examples: how `/targetexact` spells a two-part name (`state.targetNameForm`), what `UNIT_SPELLCAST_SENT` gives as the target, key-down versus key-up casting, the order of a refused cast's error and its `UNIT_SPELLCAST_FAILED`, `state.castLandsOn`, which role APIs exist, how battlegrounds signal their preparation phase (#71).

## Extending it

The rules are in CLAUDE.md's [Tests](../CLAUDE.md#tests) section; in short:

1. **Realistic.** New behaviour must be something the game does. A test hook that the game can't do (such as `state.castLandsOn`) must still keep the game's rules: #84 found that a cast `state.castLandsOn` redirects skips the macro's conditions on the unit it lands on, so the client can land a buff on a dead or hostile unit; 18 of the buff back storm's seeds 1–500 fail for it. Until its fix (#94) merges, don't rely on `castLandsOn` keeping the conditions.
2. **Pessimistic when unsure.** Choose the behaviour that is harder on the addon, and say so in the comment. Examples already in the client: `/targetexact` can't find a player known only as your target; a resurrection in a battleground gives a Preparation aura again; text widths are a little wider than the game's.
3. **Documented.** Add the behaviour to the ASSUMPTIONS block, and add what to verify in game to #50.
4. **Test-wide defaults** go in `wow.boot` with an opt-out, like `opts.autoBuffMode`. Read the given saved settings (`opts.db`) before loading fills in defaults, or the opt-out can't tell what the spec asked for.
5. **Tested.** A change to the simulated client is reviewed like addon code, and its own behaviour has tests in `spec/wow_spec.lua`. A change to a test helper after a review approved goes back to that review (#72).
6. **Unknown widget methods** (capitalised names such as `SetJustifyH`) are accepted as no-ops; unset data fields stay `nil`, so a test can't be fooled by a value the client never set. When a test needs a no-op method to do something, give it real behaviour and a test of its own.

## Several clients

For behaviour between two copies of the addon (#32), `wow.newClient({ name, surname, before })` boots a whole client, with its own globals, state and records, and leaves it live. Only one client is live at a time:
- `wow.use(client)` saves the live one and puts another's globals and simulator state in place.
- `wow.network({ a, b })` and `wow.deliver(net)` carry each client's addon messages to the others as `CHAT_MSG_ADDON`, answers included, until none are left:
  - a whisper goes only to the player it names;
  - a group or guild message goes to clients in that group (with the sender in it) or a guild;
  - a group or guild message also comes back to its sender, as in the game;
  - a client gets only the prefixes it registered.
- `wow.advanceAll(net, seconds, step)` moves every client's clock on together, delivering after each step.
- `state.addonSenderForm` (`"hyphen"` or `"space"`) sets how a receiving client spells the sender: a launch check (#50).

The network's own behaviour is tested in `spec/wow_comm_spec.lua`.

## Time and randomness

- **Time:** `wow.now` is the game clock (`GetTime()`), starting at 1000; `state.clock` is the wall clock (`time()`). `wow.advance(seconds)` runs due timers in order and moves the clock. Nothing waits in real time.
- **Randomness:** chaos (red) specs use `spec/support/random.lua`, a seeded MINSTD generator, so a seed runs the same storm on every computer. Lua 5.1's `math.random` uses the platform's C `rand()`, so a seed ran one storm on Linux and another on macOS (#76, #87). A failing seed found by hand is added to the spec's committed seed list.
