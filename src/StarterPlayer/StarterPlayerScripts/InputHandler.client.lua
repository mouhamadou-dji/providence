-- InputHandler.client.lua
-- Wires player inputs to server RemoteEvents. Server validates state; client fires only.
--
-- 2026-08-02 COMBAT TEARDOWN: every combat binding was removed with the combat stack
-- (M1/M2, F parry+block, Ctrl+M1 sweep critical, R critical, B execute, V carry,
-- G posture drain, the client-side attack/parry animation predictor, and the OnHit /
-- OnParryResult / OnM1Denied / OnParryDenied / PlayCombatAnim listeners). Those remotes
-- no longer exist, and WaitForChild on each was costing 5s of startup stall apiece.
-- The old file is archived at ServerStorage._OldCombat_2026_08_02.Client if the revamp
-- wants the prediction logic back.
--
-- NOTE: E used to toggle fists here, which double-bound against the "E - Interact"
-- prompt in InteractPromptClient. That toggle is gone; E is now purely Interact.
--
-- 2026-08-04 MOVEMENT TEARDOWN: Q dash, W double-tap sprint, Ctrl-while-sprinting slide
-- and the Space -> RequestJump fire were removed with the movement stack. Their remotes
-- (RequestDash / RequestSprint / RequestSprintEnd / RequestSlide / RequestJump) are
-- archived at ServerStorage._OldMovement_2026_08_04.Remotes and no longer exist in
-- ReplicatedStorage, so re() on any of them would just stall 5s and return nil.
-- Space is now plain Roblox jump -- nothing client-side needs to fire for it.
--
-- 2026-08-04 MOVEMENT REVAMP: sprint and Q (dash/dodge) came back, but they are
-- bound in StarterPlayerScripts.MovementClient, NOT here -- that script already owns the
-- per-frame movement state those inputs depend on (walkPower, grounded, facing), so
-- splitting the binding across two scripts would just mean shuttling state between them.
--
-- 2026-08-07 KEYBIND REBIND: Ctrl crouch moved to MovementClient too, and for the same
-- reason -- Ctrl is now one context-sensitive key (faster than
-- Config.Movement.Slide.SlideOverCrouchSpeed = slide, otherwise crouch), and only that
-- script knows the speed, the slide state machine, and the chain from a decayed slide
-- into the crouch. The round-trip crouch prediction went with it (expressed through the
-- move vector there, not the WalkSpeed write it used here). Sprint became double-tap W;
-- Shift and C are unbound.
--
-- What remains here: P outfit, Tab journal.

local UIS        = game:GetService("UserInputService")
local RepStorage = game:GetService("ReplicatedStorage")
local Players    = game:GetService("Players")

local localPlayer = Players.LocalPlayer

local RemoteEvents = RepStorage:WaitForChild("RemoteEvents", 10)
if not RemoteEvents then
    warn("[InputHandler] RemoteEvents folder not found -- aborting")
    return
end

local function re(name)
    -- WaitForChild with timeout; returns nil on miss (guard-checked before every fire)
    return RemoteEvents:WaitForChild(name, 5)
end

local RE_SendChatMsg = re("SendChatMessage")

local function fire(remoteEvent, ...)
    if remoteEvent then remoteEvent:FireServer(...) end
end

-- Input began
UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end

    local key = input.KeyCode

    -- P -- swap active outfit slot
    if key == Enum.KeyCode.P then
        fire(RE_SendChatMsg, "/outfit")
        return
    end

    -- Tab -- Toggle Journal locally
    if key == Enum.KeyCode.Tab then
        -- PLACEHOLDER_GUI: Journal -- replace with actual Journal toggle
        local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
        if playerGui then
            local journal = playerGui:FindFirstChild("JournalGui")
            if journal then
                journal.Enabled = not journal.Enabled
            end
        end
        return
    end
end)

-- Chat commands (/a /t /w /s) are handled server-side by ChatManager
-- via Players.PlayerAdded -> player.Chatted -- no client-side fire needed here

print("[InputHandler] Loaded -- P/Tab wired (combat bindings removed 2026-08-02, movement 2026-08-04, Ctrl crouch moved to MovementClient 2026-08-07)")
