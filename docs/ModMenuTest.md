# ABYSS — End to End Mod Menu Test
# Claude Code: read CLAUDE.md first
# This is a verification task — test everything in the mod menu works

---

## OBJECTIVE
Confirm every mod menu button and command works correctly end to end.
Two clients needed: one as mod, one as test player.
All actions must log to Discord webhook.

---

## SETUP
1. Owner account (greatmlgpd1 or Broke3n) joins server — this is the mod
2. Second test account joins server — this is the test player
3. Mod presses P — confirm mod menu opens
4. Non-mod presses P — confirm nothing happens
5. Search test player name in mod menu — confirm autofill finds them

---

## SECTION 1 — PLAYER MANAGEMENT

### Identity
- [ ] Change first name → name updates on test player in game
- [ ] Change family name → family name updates
- [ ] Set relation → relation updates in journal
- [ ] Assign race (Vampire) → test player shows race as Vampire
- [ ] Assign race back to Human → reverts correctly

### Stats
- [ ] Set Strength = 20 → test player deals more damage (0.5% × 20 = 10% bonus)
- [ ] Set Endurance = 20 → test player posture max increases
- [ ] Set Agility = 20 → test player stamina regens faster
- [ ] Reveal Strength stat → shows in test player journal as real number
- [ ] Hide stat → returns to ? in journal

### Talents
- [ ] Grant talent "Riposte" → appears in test player journal
- [ ] Revoke talent "Riposte" → removed from journal
- [ ] View talent list → shows all current talents for test player

### Title & Appearance
- [ ] Assign title "The Unbroken" → appears above test player name in world
- [ ] Remove title → title gone from above player name
- [ ] Apply scar "Slash" → cosmetic scar applied to character
- [ ] Remove scar → scar removed

### Family
- [ ] Assign family "Dumnacus" → family name updates
- [ ] Set relation "Brother" → relation updates in journal

### Currency
- [ ] Give 100 Obol → HUD updates, DataStore updated
- [ ] Remove 50 Obol → HUD updates, DataStore updated
- [ ] View balance → shows correct current balance

### Player State
- [ ] Freeze player → test player cannot move
- [ ] Unfreeze player → test player can move again
- [ ] Set Dead → test player enters Valhalla state, immune
- [ ] Set Alive → test player returns to alive state
- [ ] Bring here → test player teleports to mod position
- [ ] Kick player → test player removed from server

### Mod Tools
- [ ] Spectate → mod follows test player invisibly
- [ ] Stop spectate → mod returns to normal
- [ ] Toggle fly → mod can fly
- [ ] Toggle invisible → mod not visible to test player
- [ ] Toggle ESP → mod sees test player through walls
- [ ] Toggle godmode → mod cannot be damaged

### QTE
- [ ] Trigger QTE (5 letters, 10 seconds) → test player sees ! then QTE prompt
- [ ] Complete QTE → success registered
- [ ] Fail QTE → failure registered

---

## SECTION 2 — WORLD CONTROL

- [ ] Set PD Stage 1 → Eclipse Moon updates for all players
- [ ] Set PD Stage 3 → Eclipse Moon updates, confirmation popup appeared for stages 4/5
- [ ] Set PD Stage 5 → confirmation popup appeared, stage set after confirm
- [ ] Weather: Rain with 2 min duration → rain appears for all players, reverts after 2 min
- [ ] Weather: Fog → fog applies
- [ ] Clear weather → natural cycle resumes
- [ ] Lock server → second test account cannot join
- [ ] Unlock server → second test account can join
- [ ] Global message "Test announcement" → message appears on all screens with typewriter effect
- [ ] Lock zone "TestZone" → players cannot enter that zone

---

## SECTION 3 — ECONOMY

- [ ] Global economy view shows correct Obol total in circulation
- [ ] Guild allocation: add "Blacksmith Guild" with 500 Obol → appears in list
- [ ] Edit allocation → updates correctly
- [ ] Remove allocation → removed from list

---

## SECTION 4 — LORE BOARD

- [ ] Write lore entry "First blood was spilled today" → appears in lore record
- [ ] Post notice board "Market open in Massalia" → appears on notice board
- [ ] View lore record → shows all entries correctly
- [ ] View mod logs → shows last 50 mod actions with timestamps

---

## SECTION 5 — DISCORD LOGGING

For every action above, confirm it logged to Discord:
- [ ] Name change logged with: mod name, target, old value, new value, timestamp
- [ ] Stat change logged
- [ ] Talent grant/revoke logged
- [ ] Currency change logged
- [ ] Player state change logged
- [ ] PD stage change logged
- [ ] Weather override logged
- [ ] Global message logged
- [ ] Lore entry logged
- [ ] QTE trigger logged
- [ ] Server lock/unlock logged

---

## CRITICAL CHECKS

```lua
-- Every mod action must:
-- 1. Pass isMod() check server-side before executing
-- 2. Execute the action
-- 3. Fire to DiscordManager immediately after
-- 4. Return success/fail status to mod menu UI

-- Confirm non-mod cannot spoof mod commands:
-- Have test player attempt to fire ModCommand RemoteEvent directly
-- Server should reject silently (isMod check fails)
-- No action should execute
-- Attempt should be logged as "UNAUTHORIZED ATTEMPT" to Discord
```

---

## FINAL CHECKLIST SUMMARY
- [ ] All Section 1 items PASS
- [ ] All Section 2 items PASS
- [ ] All Section 3 items PASS
- [ ] All Section 4 items PASS
- [ ] All Section 5 Discord logs confirmed
- [ ] Non-mod cannot use mod commands
- [ ] Unauthorized attempts logged to Discord
- [ ] Mod menu panel is draggable
- [ ] Sections collapse and expand correctly
- [ ] Player autofill updates when players join/leave

Report all FAILs with description. Fix all before reporting done.
