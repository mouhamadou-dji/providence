# Providence (ABYSS)

Dark, lore-driven Roblox RPG set in Gaul, ~400 BC. R6 rig, PC-primary, parry-first
and stamina-gated combat. Progression is granted by the lore team, not auto-earned.

This repository is the **shared source mirror** of the Providence place, so both
scripters can read every system in one place, diff changes, and review each other's work.

---

## ⚠️ Read this before you edit anything

**Roblox Studio is the source of truth. This repo is an export, not a live sync.**

There is no Rojo pipeline pointed at these files. Editing a `.lua` file here and
pushing it does **not** change the game. The workflow is:

1. Make the change in Roblox Studio (the "Providence" place).
2. Re-run the export (see [Refreshing the export](#refreshing-the-export)).
3. Commit and push the resulting diff.

So: **Studio is where you write code, GitHub is where you read and review it.**
If you edit a file here directly, you must hand-apply that change in Studio too,
or the next export will silently overwrite it.

---

## Layout

`src/` mirrors the Roblox service tree one-to-one:

| Folder | Roblox location |
|---|---|
| `src/ReplicatedStorage/Shared/` | `ReplicatedStorage.Shared` — config, enums, remotes, shared model code |
| `src/ServerScriptService/Managers/` | server systems (the bulk of the game) |
| `src/ServerScriptService/Test/` | in-place test harnesses |
| `src/ServerStorage/_Old*/` | **archived dead code** — see below |
| `src/StarterPlayer/StarterPlayerScripts/` | all client systems |
| `src/Workspace/` | scripts living inside map geometry (mostly free-model leftovers) |

File extensions encode the script class, Rojo-style:

- `Foo.server.lua` → `Script`
- `Foo.client.lua` → `LocalScript`
- `Foo.lua` → `ModuleScript`
- `Foo/init.server.lua` → a `Script` that itself contains child scripts

`STRUCTURE.md` is a generated dump of the full instance hierarchy — use it to see
what remotes, GUIs, rigs and folders exist alongside the code.

---

## The systems

**Shared foundation** — `src/ReplicatedStorage/Shared/`
`Config` (every tunable in the game), `Enums`, `RemoteEvents`, `Util`,
`TalentEffects`, `MovementModel` (pure, unit-tested movement math).

**Core loop** — data, survival, and the player's body
`DataManager` (DataStore + session lock), `StaminaManager`, `BleedManager`,
`InjuryManager`, `RagdollManager`, `EdibleManager`, `PotionManager`,
`IdentityManager`, `DNAManager`.

**Combat**
`CombatCore` — see [Live seams](#live-seams). Plus `QTEManager`, `ShadowBoxManager`.

**Movement**
`MovementSystem` (server truth) + `MovementManager` (crouch + seam owner),
client-side `MovementClient` / `MovementController` (feel).

**Mobs & NPCs**
`NPCManager`, `WolfManager`, `ShroomManager`, `AllyManager`, `SpiritManager`.

**Mental state & lore**
`SanityManager`, `RageManager`, `FeelingsManager`, `LoreManager`, `RevealManager`,
`CasteManager`, `RitualManager`, `MeditationManager`, `TraitManager`, `TalentManager`.

**World**
`ZoneManager`, `WeatherManager`, `LightingManager`, `OceanManager`, `BoatManager`,
`FloatablesManager`.

**Crafting & economy**
`MiningManager`, `SmeltingManager`, `SmithingManager`, `TailoringManager`,
`FarmingManager`, `InteractableManager`, `InventoryManager`, `TradeManager`.

**Presentation & social**
`HUDManager` (server + client halves), `ChatManager`, `LanguageManager`,
`EmoteManager`, `PushupsManager`.

**Moderation & tooling**
`ModManager`, `BanManager`, `DiscordManager`, `BToolsManager` (in-game build tools).

Client counterparts live in `src/StarterPlayer/StarterPlayerScripts/` and are named
to match (`RageManager` → `RageClient`, and so on).

---

## Live seams

Two systems were torn down for revamps and left behind documented plug-in points.
Read the header comment of each before touching combat or movement.

- **`CombatCore.server.lua`** — the 2026-08-02 combat teardown seam. It keeps the old
  global names alive, splitting them into *real* concerns it still implements (the
  WalkSpeed pipeline, generic damage application) and *inert* combat questions that
  answer "no" until a new system registers. Plug a revamp in with
  `_G.CombatSystem = <your module>`. Do **not** overwrite `_G.CombatManager`.

- **`MovementSystem.server.lua`** — registers as `_G.MovementSystem`. The split is
  client owns *feel* (momentum, dash motion, animation), server owns *truth* (stamina,
  dodge stock, i-frames, displacement guard). Nothing in the movement stack writes
  `Humanoid.WalkSpeed` directly; sprint raises the authorised ceiling through
  `MovementManager.setMovementState` → `CombatCore.setSpeed` so the
  health/injury/rage/caste multipliers still compose.

### Archived code

`src/ServerStorage/_OldCombat_2026_08_02/` and `src/ServerStorage/_OldMovement_2026_08_04/`
are the **pre-teardown stacks, kept inert for reference**. They do not run. Read them
for prior art; do not wire them back up.

---

## Docs

`docs/` carries the design material:

- `GDC_Reference.md` — game design doc reference
- `CombatSystem.md` — combat design spec
- `MassaliaWorldBuild.md` — world / setting reference
- `CharacterCreation.md`, `HUDWiring.md`, `JournalSystem.md`,
  `DataStoreTest.md`, `ModMenuTest.md` — per-system notes
- `CLAUDE_LEGACY_SPEC.md` — the original build spec and test log.
  **Partly outdated**: its "Rojo file structure" section and its combat/movement
  chapters describe the pre-teardown architecture. The Config/Enums/DataStore
  schema sections and the test log are still useful history.

---

## Refreshing the export

Requires Node and the Roblox Studio MCP/Command Bar. From the repo root:

```bash
node tools/export_receiver.js "C:\path\to\providence"
```

Then open the Providence place in Studio, paste the contents of
`tools/export_from_studio.luau` into the Command Bar, and run it. It walks every
service and POSTs each script's source to the local receiver on `127.0.0.1:8777`,
which writes the files. Stop the receiver with Ctrl+C when it prints the script count.

The receiver only binds to localhost and only writes inside the folder you pass it.

Then review and commit as normal:

```bash
git add -A
git status
git commit -m "Export from Studio: <what changed>"
git push
```

Because the export rewrites every file, `git diff` after an export is exactly the set
of changes made in Studio since the last one — that is the whole point of the mirror.

---

## Conventions

- **Server owns all state.** Clients fire inputs; never trust a client-sent value.
- **No `Touched` for combat** — use `GetPartBoundsInBox`.
- **DataStore writes go through `UpdateAsync`**, pcall-wrapped with retries. Never `SetAsync`.
- **Rate-limit every RemoteEvent** server-side.
- Placeholders are tagged so they can be found and swapped:
  `-- PLACEHOLDER_ANIMATION:`, `PLACEHOLDER_SOUND:`, `PLACEHOLDER_ASSET:`,
  `PLACEHOLDER_WEBHOOK:`, `PLACEHOLDER_GROUPID:`.

## Secrets

The Discord webhook and mod group ID are still `PLACEHOLDER_*` in `Config.lua` —
nothing sensitive is committed. **Keep it that way.** When the real webhook and group
ID go in, set them in Studio only and do not export those lines to this repo, or move
them behind a non-committed config.
