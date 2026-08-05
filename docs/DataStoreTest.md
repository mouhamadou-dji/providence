# ABYSS — DataStore Session Test
# Claude Code: read CLAUDE.md first
# This is a verification task — do not add new features

---

## OBJECTIVE
Confirm that all player data saves and loads correctly across server joins.
Fix any issues found. Do not add new systems during this task.

---

## TEST SEQUENCE

### Test 1 — Fresh Join
1. Join server as a new player with no existing data
2. Character creation screen should appear
3. Select gender, confirm
4. Confirm data written to DataStore:
   - FirstName, FamilyName, Relation generated correctly
   - Gender matches selection
   - Race = "Human"
   - PlayerState = "Alive"
   - Hunger = 100, all stats = 0, all currency = 0
   - CreatedAt timestamp set

### Test 2 — Rejoin with existing data
1. Leave server after Test 1
2. Rejoin same server
3. Character creation screen should NOT appear
4. Confirm data loaded correctly:
   - Same name as before
   - Same gender
   - PlayerState still "Alive"
   - All values preserved exactly

### Test 3 — Stat assignment persistence
1. Lore team assigns Strength = 20 via mod menu
2. Leave server
3. Rejoin
4. Confirm Strength = 20 still in DataStore
5. Confirm stat scaling applies correctly on load (damage should reflect 20 Strength)

### Test 4 — Currency persistence
1. Give player 100 Obol via mod menu
2. Leave server
3. Rejoin
4. Confirm Obol = 100 in DataStore and displays in HUD

### Test 5 — Talent persistence
1. Assign talent "Riposte" via mod menu
2. Leave server
3. Rejoin
4. Confirm Talents table contains "Riposte"
5. Confirm talent effect is active

### Test 6 — Session lock
1. Have player join server A
2. While still on server A, attempt to join server B simultaneously
3. Server B should reject or queue the join with message:
   "Your data is being used on another server. Please wait."
4. After leaving server A, joining server B should succeed

### Test 7 — Data loss prevention
1. Simulate a server crash mid-session (use shutdown command)
2. Rejoin
3. Confirm no data was lost — all values from before shutdown preserved
4. This confirms pcall retry logic on UpdateAsync is working

---

## WHAT TO CHECK IN CODE

```lua
-- Confirm these patterns exist in DataManager:

-- 1. UpdateAsync (not SetAsync) used for ALL writes
-- 2. pcall wrapper with retry on every DataStore operation
-- 3. Session lock acquired on PlayerAdded, released on PlayerRemoving
-- 4. Auto-save fires on every significant state change
-- 5. Data loaded into a local cache on join (not read from DataStore every request)
-- 6. PlayerRemoving fires a final save before player leaves
-- 7. game:BindToClose() fires a final save for all players on shutdown

-- game:BindToClose() is critical — without it data is lost on shutdown
game:BindToClose(function()
    for _, player in ipairs(game.Players:GetPlayers()) do
        savePlayerData(player)  -- synchronous save
    end
end)
```

---

## KNOWN RISK AREAS
- If BindToClose is missing: data lost on server shutdown
- If session lock not released on crash: player locked out until lock expires
- If saving on PlayerRemoving only: race condition possible on unexpected disconnect
- If using SetAsync: concurrent write conflicts possible

---

## TEST CHECKLIST
- [ ] Test 1 PASS — fresh join creates data correctly
- [ ] Test 2 PASS — rejoin loads data without creation screen
- [ ] Test 3 PASS — stat assignment persists across rejoin
- [ ] Test 4 PASS — currency persists across rejoin
- [ ] Test 5 PASS — talents persist across rejoin
- [ ] Test 6 PASS — session lock prevents duplicate load
- [ ] Test 7 PASS — no data loss on shutdown
- [ ] UpdateAsync confirmed (not SetAsync) in all write operations
- [ ] BindToClose confirmed present
- [ ] pcall retry confirmed on all DataStore calls
- [ ] Session lock acquire and release confirmed

Report each PASS or FAIL. Fix all FAILs before reporting done.
