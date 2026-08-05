# ABYSS — HUD Final Wiring
# Claude Code: read CLAUDE.md and docs/GDC_Reference.md first

---

## OBJECTIVE
Wire all HUD elements to real server values using placeholder bar GUIs
that already exist in StarterGui/_GUIs/. Every element must update in
real time from actual game data — no hardcoded values.

---

## CURRENT STATE
All GUI folders exist in StarterGui/_GUIs/ with placeholder designs.
This task wires real data into those placeholders.
Do NOT redesign the GUIs — wire the existing ones.

---

## ELEMENT 1 — HEALTH BAR
```lua
-- Location: StarterGui/_GUIs/HUD/HealthBar
-- Updates when: Humanoid.HealthChanged fires
-- Source: Humanoid.Health / Humanoid.MaxHealth
-- Display: fill width as percentage of max
-- Color: dark red (#8B1A1A) — do not change placeholder color
-- No number label — bar only
-- PLACEHOLDER_GUI: HealthBar
local humanoid = character:WaitForChild("Humanoid")
humanoid.HealthChanged:Connect(function(health)
    local pct = health / humanoid.MaxHealth
    healthBarFill.Size = UDim2.new(pct, 0, 1, 0)
end)
```

## ELEMENT 2 — STAMINA BAR
```lua
-- Location: StarterGui/_GUIs/HUD/StaminaBar
-- Updates when: server fires UpdateHUD with stamina value
-- Source: StaminaManager server value
-- Display: fill width as percentage of max stamina
-- Remove any "Label" text that exists on this bar — bar only
-- PLACEHOLDER_GUI: StaminaBar
RemoteEvents.UpdateHUD.OnClientEvent:Connect(function(data)
    if data.stamina then
        local pct = data.stamina / data.maxStamina
        staminaBarFill.Size = UDim2.new(pct, 0, 1, 0)
    end
end)
```

## ELEMENT 3 — HUNGER BAR
```lua
-- Location: StarterGui/_GUIs/HUD/HungerBar
-- Updates when: server fires UpdateHUD with hunger value
-- Source: HungerManager server value
-- Display: fill width as percentage of max hunger (100)
-- PLACEHOLDER_GUI: HungerBar
```

## ELEMENT 4 — CURRENCY DISPLAY
```lua
-- Location: StarterGui/_GUIs/HUD/CurrencyDisplay
-- Updates when: server fires UpdateHUD with currency data
-- Display format: show highest non-zero denomination
--   If Royal Stater > 0: show "X Royal"
--   Else if Stater > 0: show "X Stater"
--   Else if Drachma > 0: show "X Drachma"
--   Else: show "X Obol"
-- Small sigil icon next to text (PLACEHOLDER_ASSET: CurrencyIcon)
-- PLACEHOLDER_GUI: CurrencyDisplay
```

## ELEMENT 5 — ECLIPSE MOON
```lua
-- Location: StarterGui/_GUIs/EclipseMoon/EclipseMoonFrame
-- Updates when: server fires UpdateEclipseMoon with stage 0-5
-- Display: swap ImageLabel.Image based on stage
-- Position: lower right corner of screen
-- Always visible — never hidden
local EclipseMoonAssets = {
    [0] = "PLACEHOLDER_ASSET: EclipseMoon_Stage0",
    [1] = "PLACEHOLDER_ASSET: EclipseMoon_Stage1",
    [2] = "PLACEHOLDER_ASSET: EclipseMoon_Stage2",
    [3] = "PLACEHOLDER_ASSET: EclipseMoon_Stage3",
    [4] = "PLACEHOLDER_ASSET: EclipseMoon_Stage4",
    [5] = "PLACEHOLDER_ASSET: EclipseMoon_Stage5",
}
RemoteEvents.UpdateEclipseMoon.OnClientEvent:Connect(function(stage)
    moonImage.Image = EclipseMoonAssets[stage]
end)
```

## ELEMENT 6 — ZONE NOTIFY
```lua
-- Location: StarterGui/_GUIs/ZoneNotify/ZoneNotifyFrame
-- Triggers when: server fires ShowZoneNotify with zone data
-- Display: fade in zone name + description, center top of screen
-- Duration: visible for 4 seconds then fade out
-- Hidden by default
-- PLACEHOLDER_GUI: ZoneNotifyFrame
RemoteEvents.ShowZoneNotify.OnClientEvent:Connect(function(name, description)
    zoneNameLabel.Text = name          -- "???" if undiscovered
    zoneDescLabel.Text = description   -- "???" if undiscovered
    -- tween in, wait 4s, tween out
    local tweenIn = TweenService:Create(frame, TweenInfo.new(0.4), {BackgroundTransparency = 0.3})
    tweenIn:Play()
    task.delay(4, function()
        local tweenOut = TweenService:Create(frame, TweenInfo.new(0.4), {BackgroundTransparency = 1})
        tweenOut:Play()
    end)
end)
```

## ELEMENT 7 — GLOBAL MESSAGE
```lua
-- Location: StarterGui/_GUIs/GlobalMessage/GlobalMessageFrame
-- Triggers when: server fires ShowGlobalMessage with text
-- Display: typewriter animation, above health bar area
-- Styled differently from zone notify — bolder, distinct
-- Discord messages tagged [FROM DISCORD] in different color
-- PLACEHOLDER_GUI: GlobalMessageFrame
-- PLACEHOLDER_SOUND: global_message — brief sound on message appear
RemoteEvents.ShowGlobalMessage.OnClientEvent:Connect(function(text, isDiscord)
    local displayText = isDiscord and "[FROM DISCORD] " .. text or text
    -- typewriter effect: reveal one character at a time
    -- duration based on text length
    -- auto-hide after full reveal + 5 second pause
end)
```

## ELEMENT 8 — POSTURE BAR (BillboardGui)
```lua
-- Already confirmed working from PostureManager
-- Confirm these rules are still enforced:
-- Hidden at 0 posture (frame invisible)
-- Appears when posture > 0 (fade in 0.15s)
-- Disappears when posture returns to 0 (fade out 0.15s)
-- Vertical bar, right side of character
-- Color: white 0-50%, yellow 50-75%, red 75-100%
-- Size: {0,5},{0,52} — thin and small
-- Visible ONLY to local player
-- NOT visible to other players
```

---

## UPDATE FREQUENCY RULES
- Health: event-driven (HealthChanged)
- Stamina: server fires on every stamina change — rate limited to max 10 updates/sec
- Hunger: server fires every 5 seconds (slow drain) and on significant change
- Currency: server fires only on change
- Eclipse Moon: server fires only on stage change
- Zone Notify: server fires on zone entry/exit
- Global Message: server fires when mod sends one

Do NOT poll values every frame — event-driven only.

---

## TEST CHECKLIST
- [ ] Health bar depletes and refills correctly
- [ ] Stamina bar depletes on action and regens correctly
- [ ] Hunger bar drains slowly over time
- [ ] Currency displays highest denomination correctly
- [ ] Eclipse Moon shows correct stage image (use placeholder assets)
- [ ] Zone notify fades in on zone entry, fades out after 4 seconds
- [ ] Shows ??? for undiscovered zones
- [ ] Global message appears with typewriter effect
- [ ] Discord message shows [FROM DISCORD] tag
- [ ] Posture bar hidden at 0, appears when filling
- [ ] Posture bar color shifts correctly
- [ ] Posture bar only visible to local player
- [ ] No Label text on stamina bar
- [ ] All updates are event-driven, not frame polling

Report each PASS or FAIL.
