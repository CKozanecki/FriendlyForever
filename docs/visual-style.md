# Visual style

The addon's look (#46). Where this differs from the code, `Colours.lua` wins and this file is fixed.

## Colours

Every colour the addon shows is named once, in `Colours.lua`, and used by name: `ns.Colours.Text(name, text)` for chat and font strings, `ns.Colours.RGB(name)` for a tooltip line or `SetTextColor`, `ns.Colours.RGBA(name)` for a texture. `spec/colours_spec.lua` fails on a colour anywhere else: a `|c` escape, a `\124` pipe, a `*Color*` call that doesn't take its colour from the palette, a tooltip line given numbers, or one of the game's colour tables (`NORMAL_FONT_COLOR` and the like).

`RGB` returns exactly three values. A tooltip line that wraps takes them into locals first (`local r, g, b = ns.Colours.RGB("text")`), since a call in the middle of an argument list gives only its first value.

| Name | Hex | Used for | On black | On tooltip navy `0b1229` | On panel grey `262626` |
|---|---|---|---|---|---|
| `title` | `ffd27a` | the addon's name in chat, the buff button's "Buff mode:" label, its tooltip's subtitle | 14.8 | 13.0 | 10.6 |
| `good` | `6cc8ff` | on, enabled, sent, open | 11.3 | 10.0 | 8.2 |
| `bad` | `ff6e86` | off, disabled, errors | 7.8 | 6.9 | 5.6 |
| `warn` | `f5a623` | snoozed, notes, the nameplate warning | 10.4 | 9.1 | 7.5 |
| `muted` | `a8adbf` | hints in brackets, debug lines | 9.4 | 8.3 | 6.8 |
| `text` | `d6d6d6` | tooltip body text | 14.4 | 12.8 | 10.4 |
| `bright` | `ffffff` | the click a tooltip line names, what the buff button casts | 21.0 | 18.5 | 15.1 |
| `shade` | `000000` at 60% | the panel behind the buff button's text | | | |

- **Contrast:** every text colour reads at least 4.5:1 (WCAG AA) on all three backgrounds; the spec checks it.
- **Colour-vision deficiency:** `good` and `bad` are a blue and a rose, not a green and a red, so they stay apart when simulated (Machado et al. 2009, full severity): CIELAB ΔE 60 under deuteranopia, 40 under protanopia and 112 under tritanopia, where the old green and red were 32 apart under deuteranopia. The spec checks at least 35.
- **Never colour alone:** "on" and "off", "Enabled" and "Disabled" stay in words; colour only helps.
- **Fonts:** the game's font objects (`GameFontNormal`, `GameFontHighlightSmall` and so on) keep their own colours.

## Scroll, don't overflow

The owner's rule (2026-10-29, on #46): any options page, list or window whose content can grow (lists of names, profiles, ledger entries, future settings) scrolls rather than overflowing or trimming content to fit. Scrollable sections share one look (frame, scroll bar, padding), and the UI simulator's layout checks run each page filled with realistic data.
