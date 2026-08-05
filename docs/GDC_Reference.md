# ABYSS — GDC Quick Reference
# Full version: ABYSS_GDD_v0.4.docx
# This file exists so Claude Code can reference system specs without opening the docx

---

## SETTING
- Gaul (France), ~400 BC
- Main hub: Massalia (Marseille) — Greek colony port city
- Gaulish tribes in interior, Greek colonists on coast, darker forces everywhere
- Berserk-inspired tone — grim, consequence-heavy, sparse

---

## COMBAT QUICK REF

### Keybinds
| Input | Action |
|-------|--------|
| M1 | Light Attack (cost: 8 stamina) |
| M2 | Heavy Attack (cost: 18 stamina) |
| F tap | Parry (cost: 12 stamina) |
| F hold | Block (cost: 5/sec) |
| Q | Dash (cost: 10 stamina) |
| W x2 | Sprint (cost: 3/sec) |
| G hold | Manual posture drain (stationary only) |
| R | Critical / Riposte (context sensitive) |
| E | Interact / Execute |
| Tab | Open Journal |
| /a [text] | Action command — shown as *Name does X* to all |
| /t [text] | Lore team message — mods only |

### Parry Windows
- Perfect Parry: frames 1–4 → full stagger, free punish
- Late Parry: frames 5–14 → light stagger
- Whiff: 12 stamina lost, posture built, punishable
- Cooldown: 0.6s after any parry input

### Posture Bar
- Visible to self only — floats next to character
- Fills: whiff (+15), got parried (+20), blocking (+10)
- Guard Break: max posture + block again OR critical hit
- On break: full reset to 0, 1.5s GuardBroken state
- Manual drain: hold G while stationary (15/sec)
- Natural drain: 5/sec out of combat, 0 mid-combat

### Clash
- Two M2s frame-perfect → Clash triggered
- Input race — 5 inputs, 3 seconds
- Winner: refund stamina, knockback, free punish
- Loser: 10 stamina drain, 0.8s stagger

---

## PERMADEATH — ECLIPSE MOON STAGES

| Stage | Moon State | Rules |
|-------|-----------|-------|
| 0 | Full bright moon | No PDE possible |
| 1 | Shadow creeping | Named kills log |
| 2 | Half eclipsed | Zone discoveries register |
| 3 | Nearly full eclipse | PDEs possible |
| 4 | Sliver of light | Bounty system active |
| 5 | Full eclipse — The Abyss | PDEs anywhere |

---

## CHARACTER DATA SCHEMA (summary)
- FirstName, FamilyName (randomly generated, overridable)
- Relation (randomly assigned: Brother/Sister/Twin/Cousin/DistantRelative/None)
- Gender (player chooses)
- Race (Human default, lore team assigns others)
- PlayerState: Alive / Dead (Valhalla)
- Stats: Strength, Endurance, Agility (all ? until revealed)
- Currency: Obol / Drachma / Stater / RoyalStater (10x conversions)
- Hunger: 0–100
- Talents: [] (lore team assigned only)
- Title: string (lore team assigned)
- Scars: [] (lore team assigned)
- Inventory: [] weapons/items
- Reputation: {Gauls, Greeks, Military} (hidden)
- DiscoveredZones: [] (resets on wipe)
- BountyActive, BrandActive, PDEFlagged

---

## RACES
| Race | Effect |
|------|--------|
| Human | Default — no effects |
| Vampire | Sun burn damage unless Sun Immunity talent |
| Dwarf | TBD |
| Apostle | TBD |
| God Hand | Future — not assignable at launch |

---

## CURRENCY
| Tier | Name | Conversion |
|------|------|-----------|
| 1 | Obol | base |
| 2 | Drachma | 10 Obols |
| 3 | Stater | 10 Drachma |
| 4 | Royal Stater | 10 Stater |

---

## BIOMES (Launch)
Coast, Dense Forest, Open Plains, Ruins, Swamp, Great Forests, Torn Castles, Forts, Strongholds

---

## MOD OWNERS (hardcoded)
greatmlgpd1 / Broke3n

---

## HUNGER
- Drains faster when healing
- Drains slowly when not in combat
- At zero: stamina regen halved, heal speed drastically reduced

---

## VALHALLA (death state)
- PlayerState = "Dead"
- Full immunity — cannot deal or receive damage
- Still visible in world
- Press E on statue to wipe → confirmation screen
- On wipe: everything resets, new character immediately

---

## PLACEHOLDER FORMAT
Every placeholder in scripts must use this format:
```lua
-- PLACEHOLDER_ANIMATION: name — replace with AnimationId
-- PLACEHOLDER_SOUND: name — replace with SoundId
-- PLACEHOLDER_GUI: name — replace with actual design
-- PLACEHOLDER_ASSET: name — replace with asset ID
-- PLACEHOLDER_WEBHOOK: name — replace with URL
-- PLACEHOLDER_GROUPID: replace with Roblox group ID
-- PLACEHOLDER_RANKID: replace with rank number
```

---

## COMBAT TAG SYSTEM

| Rule | Detail |
|------|--------|
| Tagged by | Receiving a hit from a player or mob |
| Not triggered by | Fall damage, self damage, environmental damage |
| Who gets tagged | Hit receiver only — attacker never tagged by dealing damage |
| Duration | 60 seconds from last hit received |
| Timer reset | Resets on every new valid hit received |

### Effect on systems while tagged IN COMBAT
- Stamina regen: +2/tick (vs +5/tick out of combat)
- Posture drain: 0/sec (vs 5/sec out of combat)
- Hunger drain: 0/sec (vs 0.1/sec out of combat)
