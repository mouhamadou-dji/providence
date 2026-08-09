--[[
	CombatClient -- input and presentation for level-based melee (2026-08-09).

	CLIENT OWNS FEEL, SERVER OWNS TRUTH -- the same split MovementClient keeps. This script
	binds the inputs, plays the swing clips and the local cues, and nothing else. It does not
	decide whether a swing lands, what level it was, or whether a guard held: every one of
	those is answered on the server, and every remote below is fired WITH NO PAYLOAD.

	In particular the LEVEL is never sent. This script reads MoveState only to pick which
	animation to play; the server derives the real level from its own replicated crouch/slide
	state. If the two ever disagree the server wins and the animation is simply the wrong
	one -- which is a cosmetic bug, not an exploit.

	BINDS: LMB = swing. RMB = guard, held for as long as you hold the button.

	THE PARRY IS THE OPENING FRAMES OF THE GUARD (reworked 2026-08-09). There is no separate
	parry input. Pressing guard opens Config.Melee.ParryWindow of parry frames server-side and
	then settles into an ordinary block. The previous design split tap-vs-hold and only fired
	the parry on BUTTON RELEASE, which is precisely why it felt dead -- you had to finish a
	whole tap before the window even opened, and a 0.2s hold threshold delayed the guard too.
	Now the press does both, immediately, with one remote.

	ANIMATION PRIORITY IS Action2, NOT Action. MovementController's suppressForeignTracks
	stops every foreign track at Action or below on each RenderStepped frame -- that is
	exactly what made the old critical animations play for a single frame and vanish.
]]

local Players           = game:GetService("Players")
local UIS               = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Model  = require(Shared:WaitForChild("CombatModel"))

local MCFG = Config.Melee

local remotes     = ReplicatedStorage:WaitForChild("RemoteEvents", 10)
local RE_Swing    = remotes:WaitForChild("RequestSwing", 10)
local RE_Guard    = remotes:WaitForChild("RequestGuard", 10)
local RE_GuardEnd = remotes:WaitForChild("RequestGuardEnd", 10)
-- RequestParry is deliberately NOT bound here any more: raising the guard opens the parry
-- window server-side. The remote still exists for the meleetest mod command and for a
-- future dedicated parry input, but the client never fires it.
local RE_Event    = remotes:WaitForChild("OnMeleeEvent", 10)

local character, hum, animator
local tracks = {}

local guardActive = false

-- ── Animation ─────────────────────────────────────────────────────────────
local function loadTracks(anim)
	tracks = {}
	if not anim then return end
	for i, id in ipairs(MCFG.Anims or {}) do
		local a = Instance.new("Animation")
		a.AnimationId = id
		local ok, t = pcall(function() return anim:LoadAnimation(a) end)
		if ok and t then
			-- Action2, deliberately: see the header. Action or below is stopped every frame
			-- by MovementController while any locomotion clip is playing.
			t.Priority = Enum.AnimationPriority.Action2
			t.Looped = false
			tracks[i] = t
		end
	end
end

local function playSwing(hitNum)
	local t = tracks[hitNum]
	if not t then return end
	for i, other in pairs(tracks) do
		if i ~= hitNum and other.IsPlaying then other:Stop(0.05) end
	end
	t:Play(0.05)
	-- Time-scale the clip into the swing so it always completes: windup plus active frames is
	-- the real length of a swing, and a clip authored longer than that would otherwise be cut
	-- off partway. Guarded on Length, which is 0 until the asset finishes loading.
	local swingLen = (MCFG.Windup or 0.3) + (MCFG.ActiveWindow or 0.12)
	if t.Length > 0 and swingLen > 0 then t:AdjustSpeed(t.Length / swingLen) end
end

-- ── Level intent (COSMETIC ONLY) ──────────────────────────────────────────
-- Read from the same MoveState vocabulary the server derives its own answer from, so the two
-- agree in every normal case -- but this value is never transmitted.
local function localLevel()
	local ms = character and character:GetAttribute("MoveState")
	return Model.levelFromState(ms)
end

-- ── Input ─────────────────────────────────────────────────────────────────
local function requestGuard()
	if guardActive then return end
	guardActive = true
	if RE_Guard then RE_Guard:FireServer() end
end

local function releaseGuard()
	if not guardActive then return end
	guardActive = false
	if RE_GuardEnd then RE_GuardEnd:FireServer() end
end

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if RE_Swing then RE_Swing:FireServer() end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		-- Immediate, on the press. The server opens the parry window as part of raising the
		-- guard, so there is nothing to wait for and no second remote to send.
		requestGuard()
	end
end)

UIS.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
	releaseGuard()
end)

-- ── Server events ─────────────────────────────────────────────────────────
if RE_Event then
	RE_Event.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		if payload.kind == "Swing" then
			playSwing(payload.hit or 1)
		elseif payload.kind == "Staggered" then
			-- Cut the swing clip: the server has already invalidated the swing, so letting the
			-- animation play out would show a strike that cannot land.
			for _, t in pairs(tracks) do
				if t.IsPlaying then t:Stop(0.1) end
			end
		end
	end)
end

-- ── Character lifecycle ───────────────────────────────────────────────────
local function acquire(char)
	character = char
	hum = char:WaitForChild("Humanoid", 10)
	animator = hum and hum:WaitForChild("Animator", 10)
	guardActive = false
	if animator then
		task.wait(0.1) -- same settle the locomotion loader uses before LoadAnimation
		loadTracks(animator)
	end
end

if player.Character then task.spawn(acquire, player.Character) end
player.CharacterAdded:Connect(acquire)

print(string.format(
	"[CombatClient] Loaded -- LMB swing / RMB guard (first %.2fs are parry frames), %d clips",
	MCFG.ParryWindow or 0.25, #(MCFG.Anims or {})))
