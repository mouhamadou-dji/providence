--[[
	MovementFlow (manager) -- the ONLY writer of Humanoid.WalkSpeed and JumpPower (2026-08-10).

	Owns one MovementFlow state per player and resolves it to the Humanoid whenever anything
	changes. Published as _G.MovementFlow.

	WHY IT EXISTS. CombatCore.setSpeed kept a single multiplier, so guard, attack, stagger,
	crouch, sprint, the Swift talent and freeze all overwrote each other with no record of who
	had asked for what. Whichever source's restore happened to be skipped left its value stuck
	forever. Named, weighted sources make removal exact: clearing "Attack" cannot disturb
	"Guard", and no source needs to know what else is live.

	THE CONTRACT for callers:
	    set(player, "Guard", W.Guard, 0.40)   -- register/refresh
	    clear(player, "Guard")                -- remove; never "restore to 1"

	Restoring to a constant is the bug -- it asserts a value the caller does not own. Clear
	your own key and let the resolver decide what is next.

	AMBIENT SCALARS (health taper, injury, rage, caste, Swift) are MULTIPLIERS, not setters:
	they scale whatever state you are in rather than competing with it. That preserves exactly
	how CombatCore already composed them, and it is what the dev described -- "guard speed
	setter + health scaler + speedboost passive".

	CLIENT OWNERSHIP. A player's character is client-owned, so a server WalkSpeed write is
	authoritative but a client that writes every frame will fight it. The winning weight is
	mirrored onto the character as MovementWeight so client-side writers can gate on it, which
	is how Vagabond arbitrates the same conflict.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Flow   = require(Shared:WaitForChild("MovementFlow"))

local MCFG = Config.Movement
local W    = MCFG.FlowWeights

local RESOLVE_CFG = {
	BaseWalkSpeed = MCFG.BaseWalkSpeed or 16,
	BaseJumpPower = MCFG.BaseJumpPower or 50,
}

-- [userId] = flow state. Reset on CharacterAdded, NOT just PlayerAdded -- the old system
-- initialised per player only, so a stuck multiplier survived death and was re-applied by the
-- next injury or rage refresh on the fresh character.
local states = {}

local function stateFor(player)
	if not player then return nil end
	local s = states[player.UserId]
	if not s then
		s = Flow.newState()
		states[player.UserId] = s
	end
	return s
end

local function charParts(player)
	local char = player and player.Character
	if not char then return nil, nil end
	return char, char:FindFirstChildOfClass("Humanoid")
end

--[[ Resolve and write. Called after every mutation -- there is no per-frame loop, because a
     value that only changes on mutation does not need one, and polling would fight the
     client's own writes far more often than this does. ]]
local function apply(player)
	local s = states[player and player.UserId]
	if not s then return end
	local char, hum = charParts(player)
	if not char or not hum or hum.Health <= 0 then return end

	local walk, jump, winName, winWeight = Flow.resolve(s, RESOLVE_CFG)

	-- Only write on a real change: assigning the same value still replicates and still
	-- competes with the owning client's own writes.
	if math.abs(hum.WalkSpeed - walk) > 0.001 then hum.WalkSpeed = walk end
	if math.abs(hum.JumpPower - jump) > 0.001 then hum.JumpPower = jump end

	-- Mirrored for client-side gating (see the header) and for debugging: reading these tells
	-- you exactly which source owns the character's speed right now, and what it resolved to.
	--
	-- MovementWalkSpeed is what lets a client-side flavour effect scale the CURRENT value and
	-- restore to it exactly, instead of snapshotting a base at spawn and drifting from every
	-- later change -- which is what left the sanity cliff-pull permanently applied.
	char:SetAttribute("MovementName", winName or "")
	char:SetAttribute("MovementWeight", winWeight or 0)
	char:SetAttribute("MovementWalkSpeed", walk)
	char:SetAttribute("MovementJumpPower", jump)
end

local MovementFlow = {}

--[[ Register or refresh a named setter. `walkMult`/`jumpMult` are multipliers of the base;
     pass nil for a stat you have no opinion about. `opts.absolute` skips modifiers and
     multipliers entirely (freeze), `opts.ignore` is a list of scalar names to skip. ]]
function MovementFlow.set(player, name, weight, walkMult, jumpMult, opts)
	local s = stateFor(player)
	if not s then return end
	Flow.setSetter(s, name, weight, walkMult, jumpMult, opts)
	apply(player)
end

function MovementFlow.clear(player, name)
	local s = states[player and player.UserId]
	if not s then return end
	Flow.clearSetter(s, name)
	apply(player)
end

function MovementFlow.has(player, name)
	local s = states[player and player.UserId]
	return s ~= nil and Flow.hasSetter(s, name)
end

-- Flat additive studs/s on top of the winning setter.
function MovementFlow.setModifier(player, name, walkAdd, jumpAdd)
	local s = stateFor(player)
	if not s then return end
	Flow.setModifier(s, name, walkAdd, jumpAdd)
	apply(player)
end

function MovementFlow.clearModifier(player, name)
	local s = states[player and player.UserId]
	if not s then return end
	Flow.clearModifier(s, name)
	apply(player)
end

-- Multiplicative scalars. Health/injury/rage/caste/talents live here.
function MovementFlow.setMultiplier(player, name, walkMul, jumpMul)
	local s = stateFor(player)
	if not s then return end
	Flow.setMultiplier(s, name, walkMul, jumpMul)
	apply(player)
end

function MovementFlow.clearMultiplier(player, name)
	local s = states[player and player.UserId]
	if not s then return end
	Flow.clearMultiplier(s, name)
	apply(player)
end

-- Re-resolve without changing anything. For scalar providers whose value changed underneath
-- us (health crossing the low-health threshold, an injury applied elsewhere).
function MovementFlow.refresh(player)
	apply(player)
end

-- Test/debug surface: what would resolve right now, and who owns it.
function MovementFlow.peek(player)
	local s = states[player and player.UserId]
	if not s then return nil end
	local walk, jump, name, weight = Flow.resolve(s, RESOLVE_CFG)
	return { walk = walk, jump = jump, winner = name, weight = weight }
end

MovementFlow.Weights = W

-- ── The ambient scalars ───────────────────────────────────────────────────
-- These were composed inline inside CombatCore.setSpeed. They are pulled here as named
-- multipliers so they compose with every source instead of only with whatever happened to
-- write the slot last.
local LOW_HEALTH_THRESHOLD = 0.3
local LOW_HEALTH_MIN_MULT  = 0.6

local function healthMult(player)
	local _, hum = charParts(player)
	if not hum or hum.MaxHealth <= 0 then return 1 end
	local frac = hum.Health / hum.MaxHealth
	if frac >= LOW_HEALTH_THRESHOLD then return 1 end
	local t = math.max(0, frac) / LOW_HEALTH_THRESHOLD
	return LOW_HEALTH_MIN_MULT + (1 - LOW_HEALTH_MIN_MULT) * t
end

--[[ Recompute every ambient scalar and re-resolve. Called on damage, and by InjuryManager /
     RageManager / TalentManager when their own state changes.

     Each provider is nil-guarded and defaults to 1, so a manager that has not loaded yet
     simply contributes nothing rather than erroring or zeroing the player. ]]
function MovementFlow.refreshScalars(player)
	local s = stateFor(player)
	if not s then return end

	local im = _G.InjuryManager
	local rm = _G.RageManager
	local cm = _G.CasteManager
	local tm = _G.TalentManager

	Flow.setMultiplier(s, "Health", healthMult(player), 1)
	Flow.setMultiplier(s, "Injury", im and im.getSpeedMultiplier and im.getSpeedMultiplier(player) or 1, 1)
	Flow.setMultiplier(s, "Rage",   rm and rm.getSpeedMult and rm.getSpeedMult(player) or 1, 1)
	Flow.setMultiplier(s, "Caste",  cm and cm.getMassaliaMovementMultiplier and cm.getMassaliaMovementMultiplier(player) or 1, 1)
	-- Swift used to be a SETTER at 1.1, which meant the next crouch or swing destroyed it
	-- permanently. getSpeedMult has existed and been unit-tested all along; it was simply
	-- never wired into the composition it was written for.
	Flow.setMultiplier(s, "Talent", tm and tm.getSpeedMult and tm.getSpeedMult(player) or 1, 1)

	apply(player)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────
local function onCharacter(player, char)
	states[player.UserId] = Flow.newState()
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum then return end

	-- JumpPower is only the live property when UseJumpPower is true. Nothing in the codebase
	-- ever set it, which left the existing JumpPower writes silently dead (or the JumpHeight
	-- ones, depending on the place default) -- setting it explicitly is what makes jump
	-- controllable at all.
	pcall(function() hum.UseJumpPower = true end)

	-- The resting entry. Without it the lineup is empty and resolve falls back to the bases,
	-- which is the same answer -- but having a named winner means MovementName is never blank
	-- and client gating always has a weight to read.
	MovementFlow.set(player, "Default", W.Default, 1, 1)

	-- Health crossing the low-health threshold changes a scalar with no other trigger.
	hum.HealthChanged:Connect(function()
		MovementFlow.refreshScalars(player)
	end)

	MovementFlow.refreshScalars(player)
end

local function onPlayer(player)
	if player.Character then onCharacter(player, player.Character) end
	player.CharacterAdded:Connect(function(char) onCharacter(player, char) end)
end

for _, p in ipairs(Players:GetPlayers()) do onPlayer(p) end
Players.PlayerAdded:Connect(onPlayer)
Players.PlayerRemoving:Connect(function(p) states[p.UserId] = nil end)

_G.MovementFlow = MovementFlow

print("[MovementFlow] Loaded -- named weighted speed/jump sources; sole writer of WalkSpeed/JumpPower")
