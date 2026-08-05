# ABYSS — Character Creation Screen
# Claude Code: read CLAUDE.md and docs/GDC_Reference.md first
# Then read this file fully before writing anything

---

## OBJECTIVE
Build the character creation screen that appears when a player first joins
or after a PDE wipe. It connects directly to DataManager and sets up the
player's initial character data.

---

## WHEN IT APPEARS
- First time a player joins the server (no existing DataStore entry)
- After a confirmed PDE wipe (PlayerState reset to needs_creation)
- Never appears mid-session for an existing alive character

---

## SCREEN FLOW

```
1. Screen fades in over black background
2. ABYSS logo briefly shown (PLACEHOLDER_ASSET: AbyssLogo)
3. Character creation UI appears
4. Player makes their selections
5. Confirm button → data written to DataStore → character spawns in Massalia
```

---

## UI ELEMENTS

### Layout
- Full screen dark overlay (black, opacity 0.95)
- Centered panel, dark theme matching ABYSS aesthetic
- Blood red accents (#A31515)
- All text in monospace or Arial

### Generated Name Display
```
Your name has been chosen by fate:

[FIRST NAME]  [FAMILY NAME]
e.g. "Brennus  Dumnacus"

Relation to family: [RELATION]
e.g. "Cousin of the Dumnacus line"

(These cannot be changed — accept your name)
```
- Name and family name randomly generated from pools in Config/TraitManager
- Relation randomly assigned from pool
- No reroll button — name is fate
- Display only, player cannot edit
- PLACEHOLDER_GUI: NameDisplayFrame

### Gender Selection
```
Choose your path:

[ MALE ]    [ FEMALE ]

(Two buttons, selecting one highlights it in blood red)
```
- Must select one to proceed
- Default: neither selected, confirm button disabled
- PLACEHOLDER_GUI: GenderSelectionFrame

### Race Display
```
You are born of:

[ HUMAN ]
(All characters begin as Human. 
 Fate may change this in time.)
```
- Display only — no selection
- Race is always Human at creation
- Lore team assigns other races later
- PLACEHOLDER_GUI: RaceDisplayFrame

### Confirm Button
```
[ ENTER THE WORLD ]
```
- Disabled until gender is selected
- On click: write all data to DataStore, spawn character, fade out screen
- PLACEHOLDER_GUI: ConfirmButton

---

## DATA WRITTEN ON CONFIRM

```lua
-- Write to DataStore via DataManager:
characterData.FirstName = generatedFirstName
characterData.FamilyName = generatedFamilyName
characterData.Relation = generatedRelation
characterData.Gender = selectedGender
characterData.Race = "Human"
characterData.PlayerState = "Alive"
characterData.Hunger = 100
characterData.Stats = { Strength = 0, Endurance = 0, Agility = 0 }
characterData.Currency = { Obol = 0, Drachma = 0, Stater = 0, RoyalStater = 0 }
characterData.Talents = {}
characterData.Title = ""
characterData.Scars = {}
characterData.DiscoveredZones = {}
characterData.CreatedAt = os.time()
```

---

## SPAWN ON CONFIRM
- Teleport character to Massalia spawn point
- Fade out creation screen
- Fade in game world
- PLACEHOLDER_SOUND: spawn_ambience — brief ambient sound on world entry

---

## TEST CHECKLIST
- [ ] Screen appears on first join
- [ ] Generated name displays correctly from pool
- [ ] Relation displays correctly
- [ ] Gender selection works, highlights selected
- [ ] Confirm disabled until gender selected
- [ ] On confirm: data written to DataStore correctly
- [ ] Character spawns at Massalia spawn point
- [ ] Screen fades out cleanly
- [ ] Rejoining server does NOT show creation screen again
- [ ] After PDE wipe: screen appears again on next join

Report each PASS or FAIL.
