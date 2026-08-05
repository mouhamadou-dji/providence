# ABYSS — Massalia & Gaul World Build
# Claude Code: read CLAUDE.md and docs/GDC_Reference.md first
# Then read this file fully before starting

---

## OBJECTIVE
Build the ABYSS game world: a large open Gaul map with Massalia as the central 
walled Gaulish settlement, surrounded by varied biomes. Use Roblox's built-in 
Terrain system for realistic feel. Placeholder assets from Toolbox where 
appropriate — owner will refine visually later.

---

## SCALE & PHILOSOPHY
- BIG map — atmosphere and exploration matter more than compactness
- Realistic look via Roblox Terrain (grass, rock, water, sand, snow materials)
- Gaulish aesthetic — wood, thatch, stone, iron. NO Greek architecture yet.
- Historically Gaul in 400 BC — Celtic tribal, before Roman/Greek influence
- Every biome should feel visually distinct from the others
- Long distances between areas are FINE — travel is part of the experience

---

## MAP DIMENSIONS
- Overall map: approximately 2000 x 2000 studs minimum
- Massalia city: approximately 400 x 400 studs
- Everything outside Massalia is biome territory
- Ocean on ONE side (south) — the rest is inland

---

## MASSALIA CITY LAYOUT

### Walls
```
- Full perimeter stone/wood palisade walls around the city
- Height: ~30 studs tall
- Material: Roblox Terrain "Rock" for stone base + Parts for wooden palisade top
- Wall thickness: ~6 studs
- Wall walkway on top wide enough for players to walk (a walkable rampart)
- Watchtowers at 4 corners — simple wooden towers ~40 studs tall
- Main gate: large wooden double doors facing NORTH (inland side, main road)
- Small side gate facing WEST (path to dock area)
- No gate facing south (ocean/cliff side)
```

### Interior Districts (approximate positions)
Divide the interior into distinct zones:

```
              [Watchtower]                              [Watchtower]
                  |                                          |
                  ═════════════ NORTH WALL ═══════════════
                              [Main Gate]
                                  |
                    ┌────────────────────────┐
                    │  THE OUTER GROUNDS      │
                    │  Guard patrols,         │
                    │  grazing area           │
                    └────────────────────────┘
                                  |
              ┌───────────────────┼───────────────────┐
              │                                        │
              │        THE FIRELIT SQUARE              │
              │        (main gathering area)           │
              │        - Notice board                   │
              │        - Bonfire/central hearth         │
              │        - Cobbled ground                 │
              │                                        │
              └───────────────────┬───────────────────┘
                                  |
    ┌─────────────────────────────┼─────────────────────────────┐
    │                             |                             │
    │   FORGE QUARTER             |            THE ASHTAVERN     │
    │   (Blacksmiths)             |            (Roleplay hub)    │
    │   - Crafting stations       |            - Wooden tavern   │
    │   - Anvils, forges          |            - Tables inside   │
    │   - Wooden workshops        |            - Warm interior   │
    │                             |                             │
    └─────────────────────────────┼─────────────────────────────┘
                                  |
    ┌─────────────────────────────┼─────────────────────────────┐
    │                             |                             │
    │   IRON CROWN BARRACKS       |            THE HALL OF THE   │
    │   (Gaulish garrison)        |            CHIEFTAIN         │
    │   - Long wooden hall        |            (Lore only, locked)│
    │   - Weapons racks           |            - Grand doors     │
    │                             |                             │
    └─────────────────────────────┼─────────────────────────────┘
                                  |
                  ═════════════ SOUTH WALL ═══════════════
                                  |
                  (Cliffs → ocean below, no gate)
                                  |
                          [WEST GATE → Dock path]
```

### Spawn Point
- Located in the Firelit Square, near the bonfire
- SpawnLocation part named "MassaliaSpawn"
- Players spawn here on join and non-PDE respawn

### Notice Board (Server Announcements)
- Wooden posting board in Firelit Square
- Part named "NoticeBoard"
- Proximity prompt "Read" opens the notice UI

### Bonfire
- Central hearth in Firelit Square
- Fire effect (Roblox Fire instance) + PointLight orange glow
- Gathering focal point — atmospheric only

### Valhalla Statue
- IMPORTANT: Not in Massalia — separate isolated area
- Build a small stone circle/shrine on a cliff overlooking the ocean
- Located outside Massalia, on a peninsula east of the city
- Contains one stone statue with proximity prompt "Confirm Passage" (the wipe prompt)
- Access is teleport-only from Valhalla state — no walking path
- Name the statue "ValhallaStatue"

---

## BUILDINGS IN MASSALIA — Style Guide

All buildings use Gaulish/Celtic aesthetic:
- Wood beams (dark brown timber)
- Thatched roofs (yellow-brown, use Grass or Fabric material)
- Stone foundations (Rock material)
- Wattle-and-daub walls (light beige/brown)
- Small windows, wooden shutters
- NO marble, NO columns, NO Greek elements

Use Toolbox for building models — search terms:
- "medieval house"
- "celtic hut"
- "wooden longhouse"
- "thatched roof house"
- "viking village building" (visually similar to Gaulish for placeholders)

Skip anything that looks Greek, Roman, or castle-like.

### Building Count
- 6-8 residential huts scattered through the districts
- 3 blacksmith workshops in Forge Quarter (with crafting station parts inside)
- 1 large tavern (The Ashtavern) — with interior seating
- 1 long barracks hall in Iron Crown Barracks area
- 1 grand chieftain hall (larger, more decorated) — locked for now
- Small market stalls (4-6) around Firelit Square

---

## DOCK AREA (Separate from Massalia)

- Located WEST of Massalia, connected by a dirt path road
- Roughly 200 x 150 studs
- Contains:
  - Wooden pier extending into the water (~50 studs long)
  - 1-2 small fishing boats tied to the pier
  - Small dock master building
  - Storage crates and barrels scattered around
- This is where the future ship arc launches from (not built yet, just the dock)
- Purely atmospheric for launch — no interactive elements yet
- Name the dock area zone "TheDocks"

---

## BIOMES OUTSIDE MASSALIA

The map has these biomes surrounding Massalia in different directions:

### 1. Dense Forest — NORTH of Massalia
- Roblox Terrain: Grass base, tall tree density
- Dark canopy — reduced ambient lighting effect via Atmosphere property
- Toolbox trees: search "dark forest tree pack" or "pine tree"
- Rolling terrain — use hills and small valleys
- Add fog to this biome specifically

### 2. Open Plains — EAST of Massalia
- Terrain: Grass, flat with gentle rolling hills
- Sparse trees (5-10 scattered)
- Occasional stone outcroppings
- Long sight lines — exposed feeling
- No fog

### 3. Great Forests — NORTHEAST
- Larger, older forest than Dense Forest
- Ancient massive tree models
- Ground-level mist particle effect
- Sacred/mystical feel
- Fewer paths, more overgrown

### 4. Swamp — WEST (past the dock area)
- Terrain: mix of Grass, Mud, Water in low areas
- Twisted dead trees
- Heavy PERSISTENT fog regardless of time of day
- Slow visual — like the ground is unstable
- Standing water pools

### 5. Cliffs & Coast — SOUTH
- Terrain: Rock and Sand at water's edge
- High cliffs dropping into ocean
- Ocean water extends to the map edge
- Waves audible (ambient sound placeholder)
- Massalia sits on top of these cliffs

### 6. Ruins — SOUTHWEST (past coast)
- Terrain: Rock, some Grass
- Broken stone structures (Toolbox: "ruined temple", "broken walls")
- Older than Massalia — pre-Gaulish
- Small area, dense with ruins
- Faint eerie feel

### 7. Torn Castles — FAR NORTH (past Dense Forest)
- Terrain: Grass, Rock
- Half-destroyed medieval-style fortifications
- Toolbox: "ruined castle", "broken fortress"
- Contested lore sites
- 2-3 separate ruined castle structures

### 8. Forts — DISTRIBUTED (small, in various biomes)
- Small military positions
- Wooden palisade around a central hall
- 3 total, one each in Plains, Great Forests, near Ruins

### 9. Strongholds — 1 LOCATION, FAR EAST
- Major defensive structure
- Large stone/wood fortress
- The most defensible location on the map
- Currently unclaimed — future faction war site

---

## RIVERS & CAVES

### Rivers
- Main river flowing from NORTHEAST (Great Forests) → passing near Massalia → into ocean SOUTH
- 1-2 tributaries branching into the Forest
- Use Roblox Terrain Water material
- Approximately 15 studs wide
- Fordable in shallow areas, needs bridges elsewhere
- Simple wooden bridge near Massalia's main road

### Caves
- 3 cave systems entering hillsides:
  - One in the Cliffs south of Massalia (small)
  - One in the Great Forests (medium, deeper)
  - One connecting to the Deep Vein mining area (LARGE, primary mine entrance)
- Use Terrain Fill/Carve tools to hollow out
- Dark interiors — no natural lighting, need atmospheric lighting later

### Deep Vein Mining Camp
- Located outside Massalia, roughly NORTHWEST
- Small fortified camp at the entrance of the largest cave
- Wooden buildings for miners
- Piles of ore, mining equipment
- The Deep Vein guild HQ per lore
- Name the area "DeepVeinCamp"

---

## TERRAIN COLORS & MATERIALS

Use these Roblox Terrain materials by biome:

| Biome | Materials |
|-------|-----------|
| Massalia interior | Cobblestone paths + Grass patches |
| Forest floors | Grass + LeafyGrass + Ground |
| Plains | Grass + Ground |
| Swamp | Mud + Water + Grass |
| Cliffs/Coast | Rock + Sand |
| Ruins | Rock + Ground + Grass sparse |
| Rivers | Water |
| Cave interiors | Rock + Ground |
| Mining camp | Ground + Rock |

---

## ATMOSPHERE PER BIOME

Set atmospheric properties per zone via ZoneManager already existing:

| Biome | Fog Distance | Ambient Feel |
|-------|-------------|--------------|
| Massalia | Clear | Warm, lived-in |
| Forest | Moderate fog | Damp, close |
| Great Forests | Heavy mist ground level | Ancient, sacred |
| Plains | Clear | Open, exposed |
| Swamp | Very heavy persistent fog | Cursed, wrong |
| Coast | Sea spray, wind | Salt air |
| Ruins | Light dust particles | Eerie, empty |
| Castles | Wind through stones | Contested |
| Caves | Total darkness | Enclosed, echoing |

---

## ZONE TRIGGER BOXES

For each biome and Massalia, place an invisible zone trigger box:
- CanCollide = false
- Transparency = 1
- Named clearly: "Zone_Massalia", "Zone_DenseForest", "Zone_Swamp", etc.
- Attributes as specified in ZoneManager:
  - ZoneName (string) — display name
  - ZoneDescription (string) — description shown
  - ZoneMusic (SoundId placeholder)
  - ZoneFog (boolean)
  - ZoneFogDensity (number)
  - ZoneLocked (boolean, default false)

Zone names start as their actual name for now — the ??? undiscovered system 
handles the display on the player side per-life.

---

## BUILDING PROCESS

1. Start with the Terrain — sculpt the general topology of the whole map
2. Add water — ocean south, rivers
3. Build Massalia walls first, then interior structures
4. Build dock area
5. Populate biomes one by one — trees, ruins, forts
6. Place zone trigger boxes
7. Add ambient details (bones, campfires, banners, etc.)

Do NOT try to build everything at once. Work biome by biome.

---

## PLACEHOLDER ASSET RULES

Every Toolbox asset used should:
- Not have moderation flags/red exclamation marks
- Be geometrically simple (low-poly is fine — owner may replace later)
- Match Gaulish aesthetic (wood, stone, thatch — NO Greek columns)

Prefer these Toolbox creators for cleaner assets:
- Search "medieval kit" and sort by trending
- Prefer "@Roblox" official assets when available
- Avoid free models with scripts inside (potential viruses)

For any complex model you're unsure about — search alternatives or leave the space empty and note it for the owner.

---

## LIGHTING

- Do NOT set specific lighting values — the WeatherManager handles day/night cycle
- Confirm Lighting.ClockTime updates work correctly across the map
- Any biome-specific lighting effects (heavy fog in Swamp) should be handled via 
  Atmosphere property changes triggered by ZoneManager
- Torches/braziers in Massalia have PointLights for night atmosphere

---

## PROGRESS REPORTING

After building each major section, report to owner:
- Terrain shaping complete
- Massalia walls done
- Massalia interior buildings placed
- Dock area complete
- Biome X complete (each one separately)
- Zone triggers placed
- Ready for playtest

Do not report "map complete" until every biome, zone trigger, and named location is in place.

---

## OWNER NOTES

Certain details are intentionally light:
- No specific interior building layouts (owner will decorate)
- No NPCs (game is player-driven)
- No decorative props specified beyond category
- Owner will polish visually later — focus on structure and coverage

The goal is: a walkable, atmospheric world Claude Code can build to a playable 
state, that the owner can then refine.

Report anything unclear before starting.
