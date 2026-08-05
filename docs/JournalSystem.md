# ABYSS — Journal System (Tab Key)
# Claude Code: read CLAUDE.md and docs/GDC_Reference.md first

---

## OBJECTIVE
Wire the Tab key journal to display real DataStore data for the local player.
Journal is personal — no other player can see it.

---

## HOW IT OPENS
- Tab key pressed → journal opens
- Tab pressed again → journal closes
- Cannot open during: downed state, guard break, clash
- Journal is client-side display only — no server call needed to open

---

## JOURNAL LAYOUT

```
┌─────────────────────────────────────┐
│  CHRONICLE OF [CHARACTER NAME]      │
│─────────────────────────────────────│
│  Full Name:    Brennus Dumnacus     │
│  Family:       Dumnacus             │
│  Relation:     Cousin               │
│  Gender:       Male                 │
│  Race:         Human                │
│─────────────────────────────────────│
│  ATTRIBUTES                         │
│  Strength:     ?                    │
│  Endurance:    ?                    │
│  Agility:      ?                    │
│─────────────────────────────────────│
│  TITLE                              │
│  (None)                             │
│─────────────────────────────────────│
│  SCARS                              │
│  (None)                             │
│─────────────────────────────────────│
│  TALENTS                            │
│  (None granted)                     │
│─────────────────────────────────────│
│  DISCOVERED ZONES (this life)       │
│  (None discovered)                  │
└─────────────────────────────────────┘
```

---

## DATA RULES

### Stats display
- All stats show as ? by default
- Only show real value if stat name is in RevealedStats array
- Example:
  ```lua
  if table.find(data.RevealedStats, "Strength") then
      display = tostring(data.Stats.Strength)
  else
      display = "?"
  end
  ```

### Title
- If Title == "" → show "(None)"
- Otherwise show title string

### Scars
- If Scars table is empty → show "(None)"
- Otherwise list each scar on its own line

### Talents
- If Talents table is empty → show "(None granted)"
- Otherwise list each talent name on its own line

### Discovered Zones
- If DiscoveredZones table is empty → show "(None discovered)"
- Only shows zones discovered on current life
- Resets after PDE wipe

---

## VISUAL THEME
- Dark background matching ABYSS theme (#111111)
- Blood red section headers (#A31515)
- Light gray text (#D4D4D4)
- Monospace font for values
- Thin red border around journal frame
- PLACEHOLDER_GUI: JournalFrame — replace with final design
- Journal should feel like an old worn parchment document in spirit
  but built dark for ABYSS — dark paper, red ink headers

---

## DATA SOURCE
- Journal reads from local cached character data
- Data is cached on client when player spawns via DataManager
- UpdateHUD RemoteEvent also refreshes journal cache when data changes
- Do not make a new server request every time Tab is pressed

---

## TEST CHECKLIST
- [ ] Tab opens journal
- [ ] Tab closes journal
- [ ] Cannot open during downed/guarbreak/clash
- [ ] Name displays correctly
- [ ] Family name and relation display correctly
- [ ] Gender and race display correctly
- [ ] Stats show ? when not revealed
- [ ] Stats show real value when revealed by lore team
- [ ] Title shows (None) when empty
- [ ] Title shows correctly when assigned
- [ ] Scars list correctly
- [ ] Talents list correctly
- [ ] Discovered zones list correctly (current life only)
- [ ] Journal does not make a server call on open
- [ ] Data updates if lore team changes something mid-session

Report each PASS or FAIL.
