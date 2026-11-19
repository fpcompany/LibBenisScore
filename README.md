# LibBenisScore

Stat weights and item scores for World of Warcraft addons, shared by
[BenisAH](https://github.com/fpcompany/BenisAH) and
[BenisUI](https://github.com/fpcompany/BenisUI). It is embedded in each addon,
so players never install it separately.

- **Score**: an item's stats times the weights, plus weapon DPS (melee and
  ranged/wand apart) and a weapon speed bonus or malus.
- **Presets** for all 27 WoW Forever specs, from WoWSims Forever pre-raid stat
  weights (wowforeverbislist.com, November 2026), converted to rating points.
- **Compare** an item with what it would replace: the weaker ring or trinket,
  both hands for a two-hander, the ranged slot on Forever.
- **Tooltip line** on every item: `Upgrade for Main hand: score x -> y (+z)`.
- **Weights panel**: preset menu, weapon speed buttons (slow, fast, any speed,
  ignore), a box per weight. `/bscore` opens it in a window of its own.

Settings are per character. Each host addon hands the library a table from its
`SavedVariablesPerCharacter`; every change is written to all of them with a
time stamp and the newest wins at login, so all installed hosts agree.

## Embedding

Add the repo as a submodule and load the XML before your own files:

```sh
git submodule add https://github.com/fpcompany/LibBenisScore.git Libs/LibBenisScore
```

```
## SavedVariablesPerCharacter: MyAddonCharDB
Libs\LibBenisScore\LibBenisScore.xml
```

```lua
local Score = LibStub('LibBenisScore-1.0')

-- once the saved variables are loaded (ADDON_LOADED)
MyAddonCharDB = MyAddonCharDB or {}
MyAddonCharDB.score = MyAddonCharDB.score or {}
Score:Register(MyAddonCharDB.score)

local score, info = Score:Score(link)      -- info.usable: no red tooltip text
local result = Score:Compare(link)         -- { label, score, equippedScore, gain, equippedLink, usable }
Score:RegisterCallback(MyAddon, function() --[[ weights changed ]] end)
local panel = Score:CreateWeightsPanel(parent)
```

Set `owner.benisScoreNoLine = true` on a tooltip owner that shows its own
upgrade line.

The release zip of a host has to contain the submodule: `git archive` leaves
it out, so the packaging script archives it on its own.

## Versioning

LibStub runs only the newest copy of all those embedded in the installed
addons. Raise `MINOR` in `LibBenisScore.lua` with every change, and keep the
API backward compatible: an older host may run against a newer copy.
