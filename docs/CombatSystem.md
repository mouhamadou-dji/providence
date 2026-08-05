# ABYSS — Combat System Full Specification
# Claude Code: read this alongside CLAUDE.md before building CombatManager

---

## CORE PHILOSOPHY
Heavy and committed. Every movement has a punishment. This is not a mobile fighter —
it is a deliberate, weighty system where committing to an attack means accepting
vulnerability. Inspired by Dark Souls movement restriction, not For Honor mobility.

---

## MOVEMENT SPEED STATES

All speeds are multipliers on base WalkSpeed.

| State | Speed Multiplier | Notes |
|-------|-----------------|-------|
| Normal | 100% | Default |
| Sprinting | 160% | W x2, costs 3 stamina/sec |
| M1 chain active | 35% | Applied from animation commit frame |
| M2 (heavy) swing | 0% | Fully rooted for full swing duration |
| Parry window (F tap) | 75% | Slight slow during active parry frames only |
| Block (F hold) | 40% | Unless player has Block Movement talent |
| Block (talent) | 100% | Lore team granted talent only |
| Stagger | 30% | Can drift/stumble, cannot sprint or attack |
| Guard Break | 0% | Fully rooted for 1.5s — no input accepted |
| End lag (post chain) | 100% | Can move freely but M1 is locked |
| Feint recovery | 100% | Brief window after feint cancel |

---

## M1 CHAIN SYSTEM

### Basic Chain
- Each M1 press continues the chain
- Speed drops to 35% from the frame the attack animation commits
- Player can still rotate/turn freely to track moving targets during chain
- End lag after chain ends: M1 locked, full movement speed returns
- End lag is punishable — opponent can freely attack

### Feint (M1 → M2 mid chain)
- Pressing M2 during an active M1 chain CANCELS the M1 animation
- Does NOT fire the M2 heavy — it is a pure cancel/feint
- Costs 4 stamina flat (less than full M1 cost of 8)
- Player returns to neutral state immediately after feint
- Full speed restored after feint recovery frames
- Primary use: bait opponent into parrying at wrong time

```lua
-- PLACEHOLDER_ANIMATION: feint_cancel — replace with actual AnimationId
-- Logic: detect M2 input during M1 activeFrames window
-- If M2 during M1: cancelM1(), drainStamina(4), enterFeintRecovery()
-- Do NOT fire M2 damage or swing
```

### Running M1 (Lunge Attack)
- Triggered when: player is sprinting AND presses M1
- Pushes attacker forward on hit — lunge momentum carry
- Slightly more range than standing M1
- Stamina cost: normal M1 cost (8) — sprint drain already running
- Different animation from standing M1
- Builds normal posture on opponent

```lua
-- PLACEHOLDER_ANIMATION: running_m1_lunge — replace with actual AnimationId
-- Logic: if isSprinting AND RequestM1 → playLungeAnim(), applyForwardForce()
-- Forward force: small impulse on HumanoidRootPart toward facing direction
```

### Aerial M1 (Jump Attack)
- Triggered when: player is airborne AND presses M1
- Pushes attacker slightly forward and downward on hit
- Different animation from standing M1 and running M1
- Builds SLIGHTLY MORE posture on opponent than standard M1 (+3 bonus posture)
- On land after aerial hit: brief impact stagger on opponent (0.3s bonus stagger)
- Stamina cost: normal M1 cost (8)

```lua
-- PLACEHOLDER_ANIMATION: aerial_m1 — replace with actual AnimationId
-- Logic: if isAirborne AND RequestM1 → playAerialAnim(), applyDownwardForce()
-- On hit: postureBuilt = Config.Posture.FillM1 + 3 (aerial bonus)
-- On land contact after aerial hit: triggerBonusStagger(0.3)
```

---

## M2 HEAVY ATTACK

- Player is FULLY ROOTED (0% speed) for the entire swing duration
- Cannot be cancelled mid-swing (no feint on M2)
- High damage, high end lag
- Two M2s frame-perfect → Clash triggered
- Parry Break: M2 into active parry staggers the defender

```lua
-- PLACEHOLDER_ANIMATION: heavy_attack — replace with actual AnimationId
```

---

## PARRY SYSTEM (detailed)

### Windows
- F tap → parry attempt
- Active window: 14 frames total
  - Frames 1–4: Perfect Parry → full stagger on attacker, free punish window
  - Frames 5–14: Late Parry → light stagger, limited punish
  - After frame 14: whiff

### Movement during parry
- Speed: 75% during active parry window only
- Returns to normal immediately after window resolves

### Outcomes
| Result | Attacker Effect | Defender Effect |
|--------|----------------|-----------------|
| Perfect Parry | Full stagger (1.2s) | Free punish window |
| Late Parry | Light stagger (0.5s) | Limited punish window |
| Whiff | Free to punish | -12 stamina, +15 posture built |
| Parry Break (M2 into parry) | Nothing | Stance broken, staggered |

### Costs
- Normal parry: 12 stamina
- Parrying a Trait ability: 20 stamina
- Parry cooldown: 0.6s after any parry input

```lua
-- PLACEHOLDER_ANIMATION: parry_success — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: parry_whiff — replace with actual AnimationId
-- PLACEHOLDER_SOUND: parry_clash — replace with actual SoundId
```

---

## BLOCK SYSTEM

- F hold → block state
- Absorbs M1 hits — attacker is not staggered
- Costs 5 stamina per second held
- Builds posture on blocker (+10 per blocked hit)
- Movement speed: 40% while blocking
- Movement speed with Block Movement talent: 100%
- Block Movement talent: lore team granted only — not auto-available

```lua
-- PLACEHOLDER_ANIMATION: block_idle — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: block_hit — replace with actual AnimationId
```

---

## STAGGER STATES

### Light Stagger (Late Parry result)
- Duration: 0.5s
- Speed: 30% — can drift/stumble
- Cannot attack or parry during stagger
- Can be punished

### Full Stagger (Perfect Parry result)
- Duration: 1.2s
- Speed: 30%
- Fully punishable window

### Guard Break State
- Triggered: posture maxes out AND (blocks again OR critical lands)
- Duration: 1.5s
- Speed: 0% — fully rooted
- Cannot input anything
- R key by opponent with Riposte talent → massive damage
- Posture resets to 0 on guard break

```lua
-- PLACEHOLDER_ANIMATION: stagger_light — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: stagger_full — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: guard_break — replace with actual AnimationId
-- PLACEHOLDER_SOUND: guard_break — replace with actual SoundId
```

---

## POSTURE BAR GUI — BILLBOARDGUI

The posture bar is a BillboardGui attached to the player's character.
Visible ONLY to the local player — not to anyone else.

```lua
-- Implementation: BillboardGui parented to HumanoidRootPart
-- AlwaysOnTop = false (hidden behind walls)
-- Size: {0, 80}, {0, 10} (small bar)
-- StudsOffset: Vector3.new(0, 3, 0) — floats above character head
-- Visible: LocalPlayer only — use a LocalScript to show/hide

-- Structure:
-- BillboardGui
--   └── Frame (background, dark)
--         └── Frame (fill bar, color shifts white → yellow → red as posture fills)

-- PLACEHOLDER_GUI: PostureBarBillboard — replace with final design
-- Color logic:
--   0–50% posture: white fill
--   50–75% posture: yellow fill  
--   75–100% posture: red fill
--   Guard break flash: brief red flash animation on the bar

-- Server fires UpdatePostureBar RemoteEvent to LOCAL PLAYER ONLY
-- Client PostureBarClient.client.lua receives value and updates the BillboardGui fill
```

---

## CRITICAL & RIPOSTE (R KEY)

Context-sensitive — same key, different outcome:

| Context | Talent Required | Outcome |
|---------|----------------|---------|
| R on downed/vulnerable opponent | None | Critical hit — high damage |
| R after perfect parry on guard broken opponent | Riposte (lore team granted) | Massive damage counter |
| R with no valid context | None | Input ignored |

```lua
-- PLACEHOLDER_ANIMATION: critical_hit — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: riposte — replace with actual AnimationId
-- PLACEHOLDER_SOUND: critical_impact — replace with actual SoundId
-- Check order: 1) is opponent GuardBroken? + player has Riposte talent → riposte
--              2) is opponent in vulnerable state? → critical
--              3) neither → ignore input
```

---

## CLASH SYSTEM

- Two M2s connect frame-perfect → Clash triggered
- Camera locks to cinematic close third-person view
- Input race: 5 button sequence, 3 second window
- Winner: stamina refund (-10 net), knockback on opponent, free punish
- Loser: +10 stamina drain, 0.8s stagger, no recovery option
- Cannot escape once triggered

```lua
-- PLACEHOLDER_ANIMATION: clash_cinematic — replace with actual AnimationId
-- PLACEHOLDER_SOUND: clash_impact — replace with actual SoundId
-- PLACEHOLDER_GUI: ClashInputRace — replace with actual UI design
```

---

## FIST COMBAT

- No weapon equipped → fist mode
- Defensive option: lateral iframe dodge (not parry)
- Dodge: 8 stamina, brief iframe frames
- Fist M1 deals 60% of normal M1 damage
- Fists build posture on opponent normally
- Fists cannot trigger Clash — get knocked back instead
- Running M1 and Aerial M1 variants still apply
- Player can choose fists even if weapon is equipped

```lua
-- PLACEHOLDER_ANIMATION: fist_m1 — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: fist_dodge — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: fist_running_m1 — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: fist_aerial_m1 — replace with actual AnimationId
```

---

## COMBAT TAG

- Tagged IN COMBAT when: receive a hit from player or mob
- NOT triggered by: fall damage, environmental damage, self damage
- Only receiver gets tagged — not the attacker
- Duration: 60 seconds, resets on each new valid hit received
- Effects while tagged:
  - Stamina regen: +2/tick
  - Posture drain: 0/sec
  - Hunger drain: 0/sec
- Effects while OUT of combat:
  - Stamina regen: +5/tick
  - Posture drain: 5/sec natural
  - Hunger drain: 0.1/sec passive

---

## KNOCKBACK

- All hits apply physical knockback to HumanoidRootPart
- Force: 40 units base
- Running M1 lunge: slightly higher force (50 units) due to momentum
- Aerial M1: downward force component added
- Knockback direction: away from attacker's facing direction

---

## DAMAGE SOURCES — for combat tag and PDE checks

```lua
-- Every damage call must pass a source tag:
-- DamageSource = "Player" → combat tags receiver, counts for PDE
-- DamageSource = "Mob"    → combat tags receiver, counts for PDE in PDE zones
-- DamageSource = "Fall"   → no combat tag, no PDE trigger
-- DamageSource = "Environment" → no combat tag, no PDE trigger
```

---

## ANIMATION PLACEHOLDER FULL LIST

| Placeholder ID | When Used |
|---------------|-----------|
| m1_1, m1_2, m1_3 | M1 chain hits 1, 2, 3 |
| m1_endlag | End of M1 chain |
| m2_heavy | M2 heavy swing |
| feint_cancel | M1 cancelled by feint |
| running_m1_lunge | Sprinting M1 |
| aerial_m1 | Airborne M1 |
| parry_success | Parry lands |
| parry_whiff | Parry misses |
| block_idle | Holding block |
| block_hit | Taking hit while blocking |
| stagger_light | Light stagger |
| stagger_full | Full stagger |
| guard_break | Guard break state |
| critical_hit | R key critical |
| riposte | R key riposte (talent) |
| clash_cinematic | Clash entry |
| fist_m1 | Unarmed M1 |
| fist_dodge | Unarmed iframe dodge |
| fist_running_m1 | Unarmed running M1 |
| fist_aerial_m1 | Unarmed aerial M1 |
| idle | Default idle |
| walk | Walking |
| run | Running/sprinting |
| death | Death animation |
| execute | E key execute |

---

## POSTURE BAR VISIBILITY RULES (UPDATED)

- Posture bar is HIDDEN by default at 0 posture
- Appears (fades in) when posture value goes above 0
- Disappears (fades out) when posture returns to 0
- Keep it small — do not make it intrusive or large
- Suggested size: {0, 60}, {0, 6} — thin and compact
- No label, no number — purely visual bar
- Color shifts: white → yellow → red as posture fills
- Brief red flash on guard break, then bar resets and hides

```lua
-- BillboardGui visibility logic (PostureBarClient.client.lua):
-- if postureValue > 0 and not isVisible then fadeIn()
-- if postureValue <= 0 and isVisible then fadeOut()
-- Fade tween: 0.15s — quick but not jarring
-- PLACEHOLDER_GUI: PostureBarBillboard — small thin bar, no text
```

---

## EXECUTION SYSTEM (B KEY)

- Triggered by: pressing B when standing over a downed opponent at 0% HP
- Target must be: downed state (knocked), 0% HP, within close range
- Execution is a finishing animation — kills the target
- Long animation — interruptible if you get hit during it
- If interrupted: target survives at 1 HP, gets back up
- At PD Stage 3+: execution can trigger a PDE if conditions are met
- Friendly fire applies — you can execute allies

```lua
-- PLACEHOLDER_ANIMATION: execution — replace with actual AnimationId
-- PLACEHOLDER_SOUND: execution_impact — replace with actual SoundId
-- Logic:
-- B pressed → raycast/proximity check for downed player within range
-- if found and target.HP == 0 and target.State == "Downed":
--   lockBothPlayers(), playExecutionAnim()
--   if anim completes uninterrupted: killTarget(), triggerPDECheck()
--   if interrupted mid-anim: target.HP = 1, target.State = "Stagger", unlock()
-- Range check: ~5 studs from HumanoidRootPart
```

---

## DOWNED STATE

- Player reaches 0% HP → enters Downed state (not instant death)
- Downed: lying on ground, cannot move or attack
- Downed player can be:
  - Executed (B key) → permanent death trigger check
  - Carried (V key) → picked up by another player
  - Left alone → after a set bleed-out time they die automatically (duration TBD)
- Downed state is separate from Valhalla/PDE death — mods confirm PDE

```lua
-- PLACEHOLDER_ANIMATION: downed_idle — replace with actual AnimationId
-- State: player.CombatState = "Downed"
-- HP locked at 0 while downed — cannot go lower, cannot regen
```

---

## CARRY SYSTEM (V KEY)

- V key pressed near a downed player → pick them up and carry them
- Carrier: movement speed reduced while carrying (50% of normal speed)
- Carrier: cannot attack, parry, block, or use any combat input while carrying
- Carried player: fully limp, draped over carrier's shoulder
- V key again while carrying → drop the player at current location
- If carrier is killed while carrying → carried player drops to ground, remains downed
- Carried player can still be executed by a third party while being carried
- Use cases: drag an ally to safety, drag an enemy to a specific location for lore

```lua
-- PLACEHOLDER_ANIMATION: carry_idle — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: carry_walk — replace with actual AnimationId
-- PLACEHOLDER_ANIMATION: carried_limp — replace with actual AnimationId (on carried player)
-- Logic:
-- V pressed → proximity check for downed player within ~4 studs
-- if found: attachCarriedToCarrier (weld HumanoidRootPart offset to shoulder)
--   carrier.WalkSpeed = baseSpeed * 0.5
--   carrier.CombatLocked = true (no M1/M2/F/R/B inputs accepted)
-- V pressed again while carrying → detach, place carried player at ground position
-- If carrier dies: detach immediately, carried player drops in place
-- Carried player position: offset from carrier HumanoidRootPart
--   Vector3.new(1.5, 0, 0) — slung over right shoulder
-- PLACEHOLDER_ANIMATION: drop_carry — animation for putting them down
```

---

## UPDATED KEYBIND TABLE (FINAL)

| Input | Action |
|-------|--------|
| M1 | Light Attack (8 stamina) |
| M2 | Heavy Attack (18 stamina) / Feint cancel during M1 chain (4 stamina) |
| F tap | Parry (12 stamina) |
| F hold | Block (5 stamina/sec) |
| Q | Dash (10 stamina) |
| W x2 | Sprint (3 stamina/sec) |
| G hold | Manual posture drain (stationary only) |
| R | Critical (on vulnerable) / Riposte (on guard broken, talent required) |
| B | Execute (on downed player at 0% HP) |
| V | Carry / Drop downed player |
| E | Interact / General use |
| Tab | Open Character Journal |
| /a [text] | Action command — *Name does X* shown to all |
| /t [text] | Lore team message — mods only |
