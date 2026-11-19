# Stashed: where's the rest of this item?

Hover any item and Stashed tells you what you own **across every character, your banks, the Warband bank and your mail**. It only speaks up when it has something useful to say, so it never clutters tooltips for items that are just sitting in your bags.

```
Owned                      15  (you 12, alts 3)
  Kira                      Bags 5 · Bank 7
  Bob                       Bags 3
  Warband bank              40
```
*(Hold Shift for the per-character breakdown.)*

## Features
- **Account-wide item tooltips:** bags, bank, worn, mail, every alt and the Warband bank, with class-coloured names.
- **Quiet by default:** no line when every copy is already in the current character's bags.
- **Search window:** `/stashed herb` finds an item on any character. Hover for the full tooltip, Shift-click to link.
- **Addon Compartment button:** no minimap clutter.
- **Midnight-safe:** only reads item and container data. No combat data, no Secret Values problems.
- **Safe bank handling:** a closed or half-loaded bank can never wipe your saved data.
- **Zero dependencies**, lightweight, nothing runs in combat.

## Setup
Log in on each character once, and open your bank once to record the Warband bank. That's it.

## Commands
| Command | Does |
|---|---|
| `/stashed` | Open / close search |
| `/stashed <text>` | Search for an item |
| `/stashed config` | Options |
| `/stashed list` | Show tracked characters |
| `/stashed forget <name>` | Stop tracking a character |
