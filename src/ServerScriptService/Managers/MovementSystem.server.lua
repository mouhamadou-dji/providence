--[[
	MovementSystem -- server authority for the movement revamp (pass 1, 2026-08-04).

	Registers itself as _G.MovementSystem, which is the plug-in point MovementManager's seam
	already advertises. MovementManager keeps owning crouch and keeps owning the
	_G.MovementManager NAME (PotionManager calls mm.isSprinting with no nil-guard); its inert
	stubs delegate here automatically the moment this registers.

	THE SPLIT: the client owns FEEL -- the momentum curve, the dash motion, animation state.
	This owns TRUTH -- stamina, dodge stock, i-frames, and the displacement guard. The client
	moves first and this can deny after the fact, which is the only way to be both responsive
	and exploit-resistant.

	WALKSPEED: sprint is the one thing here that changes speed, and it does it by raising the
	authorised ceiling through MovementManager.setMovementState -> CombatCore.setSpeed, so the
	health/injury/rage/caste product still composes. Nothing in the movement stack writes
	Humanoid.WalkSpeed directly.
]]

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local MCFG     = Config.Movement
local DASHCFG  = MCFG.Dash
local DODGECFG = MCFG.Dodge
local SPRINTCFG = MCFG.Sprint

-- ── Remotes ───────────────────────────────────────────────────────────────
local function getOrCreateRE(name)
	local folder = RepStorage:FindFirstChild("RemoteEvents")
	if not folder then
		folder = Instance.new("Folder"); folder.Name = "RemoteEvents"; folder.Parent = RepStorage
	end
	local r = folder:FindFirstChild(name)
	if r then return r end
	r = Instance.new("RemoteEvent"); r.Name = name; r.Parent = folder
	return r
end

local RE_Sprint      = getOrCreateRE("RequestSprint")
local RE_SprintEnd   = getOrCreateRE("RequestSprintEnd")
local RE_Dash        = getOrCreateRE("RequestDash")
local RE_Slide       = getOrCreateRE("RequestSlide")
local RE_SlideEnd    = getOrCreateRE("RequestSlideEnd")
local RE_DodgeResult = getOrCreateRE("OnDodgeResult")
local RE_MovState    = getOrCreateRE("UpdateMovementState")

-- ── Per-player state ────────────────────────────────────────────────────────
local pState = {}

local function initState(uid)
	pState[uid] = {
		isSprinting       = false,
		isDashing         = false,
		isSliding         = false,
		slideCooldownUntil = 0,
		dashCooldownUntil = 0,
		dashEndsAt        = 0,
		dashStartPos      = nil,
		dashMaxDist       = 0,
		-- Dodge stock is regenerated LAZILY on request rather than on a timer -- no per-player
		-- heartbeat cost for a resource nobody is spending.
		dodgeStock        = DODGECFG.MaxStock,
		lastStockRegen    = os.clock(),
	}
end
local function getPS(player) return player and pState[player.UserId] end

for _, p in ipairs(Players:GetPlayers()) do initState(p.UserId) end
Players.PlayerAdded:Connect(function(p) initState(p.UserId) end)
Players.PlayerRemoving:Connect(function(p) pState[p.UserId] = nil end)

local function charParts(player)
	local char = player and player.Character
	if not char then return nil, nil, nil end
	return char, char:FindFirstChildOfClass("Humanoid"), char:FindFirstChild("HumanoidRootPart")
end

-- Talent modifiers. Both keys already exist in TalentEffects and, until now, nothing read
-- either of them: SprintStaminaDrain (RoadWorn, Marathoner) and DashCooldownMult (Duelist).
local function talentMult(player, key)
	local tm = _G.TalentManager
	if tm and tm.getModifier then
		local ok, v = pcall(tm.getModifier, player, key)
		if ok and type(v) == "number" then return v end
	end
	return 1
end

-- ── Sprint ──────────────────────────────────────────────────────────────────
local function setCeiling(player, stateName)
	local mm = _G.MovementManager
	if mm and mm.setMovementState then mm.setMovementState(player, stateName) end
end

local function stopSprint(player, s)
	s = s or getPS(player)
	if not s or not s.isSprinting then return end
	s.isSprinting = false
	local cm = _G.CombatManager
	if cm and cm.setSprinting then cm.setSprinting(player, false) end
	setCeiling(player, "Normal")
	RE_MovState:FireClient(player, "SprintEnd")
end

-- Returns (ok, reason). Split out from startSprint so a refusal can always SAY why -- both
-- for the test harness and because a silently-refused input is the single thing players
-- complained about most in the old movement stack.
local function canSprint(player, s)
	s = s or getPS(player)
	if not s then return false, "nostate" end
	if s.isSprinting then return false, "already" end
	local char, hum = charParts(player)
	if not hum then return false, "nocharacter" end
	if hum.Health <= 0 then return false, "dead" end
	local mm = _G.MovementManager
	if mm and mm.isCrouching and mm.isCrouching(player) then return false, "crouched" end
	local cm = _G.CombatManager
	if cm and cm.isActionBlocked and cm.isActionBlocked(player) then return false, "blocked" end
	if cm and cm.isSprintLocked and cm.isSprintLocked(player) then return false, "sprintlock" end
	local sm = _G.StaminaManager
	if sm and sm.get(player) < 1 then return false, "stamina" end
	return true, nil
end

local function startSprint(player, s)
	s = s or getPS(player)
	local ok, reason = canSprint(player, s)
	if not ok then return false, reason end
	s.isSprinting = true
	local cm = _G.CombatManager
	if cm and cm.setSprinting then cm.setSprinting(player, true) end
	setCeiling(player, "Sprint")
	RE_MovState:FireClient(player, "Sprint")
	return true, nil
end

RE_Sprint.OnServerEvent:Connect(function(p) startSprint(p) end)
RE_SprintEnd.OnServerEvent:Connect(function(p) stopSprint(p) end)

-- ── Dodge economy ──────────────────────────────────────────────────────────
-- Dodging is a managed resource, not a reflex you can spam. Out of stock you still GET a
-- dodge -- it is just worse (shorter i-frames, more stamina) rather than being refused,
-- because a refused input with no feedback is what made the old dash feel broken.
local function regenStock(s)
	if s.dodgeStock >= DODGECFG.MaxStock then
		s.lastStockRegen = os.clock()
		return
	end
	local now = os.clock()
	while s.dodgeStock < DODGECFG.MaxStock and (now - s.lastStockRegen) >= DODGECFG.RegenTime do
		s.dodgeStock += 1
		s.lastStockRegen += DODGECFG.RegenTime
	end
end

local function consumeDodge(player, s)
	regenStock(s)
	-- DEV TOGGLE (2026-08-08): Config.Stamina.FreeStamina frees dodge STOCK as well as
	-- stamina. Stock is a separate resource, so gating StaminaManager.drain alone still
	-- left a meter draining on every dash -- which is exactly what the dev reported.
	if (Config.Stamina or {}).FreeStamina then return "clean" end
	-- Rage is pure commitment: dodges stop costing stock, but the client has already gutted
	-- your braking and cornering in exchange.
	local rm = _G.RageManager
	if (MCFG.Rage and MCFG.Rage.FreeDodges) and rm and rm.isRaging and rm.isRaging(player) then
		return "clean"
	end
	if s.dodgeStock > 0 then
		s.dodgeStock -= 1
		if s.dodgeStock == DODGECFG.MaxStock - 1 then s.lastStockRegen = os.clock() end
		return "clean"
	end
	return "fatigued"
end

-- ── I-frames + lag reconciliation ─────────────────────────────────────────────
-- Storage and the damage gate both live in CombatCore (the single damage funnel every
-- system routes through). This only decides WHEN to grant, and asks CombatCore to undo
-- damage that landed inside the player's own latency window -- otherwise a high-ping player
-- gets hit during what was, on their screen, a clean dodge.
local function grantIframes(player, duration)
	local cm = _G.CombatManager
	if cm and cm.grantIframes then cm.grantIframes(player, duration) end
	local char = player.Character
	if char then
		char:SetAttribute("IFramesActive", true)
		task.delay(duration, function()
			if char.Parent and not (cm and cm.hasIframes and cm.hasIframes(player)) then
				char:SetAttribute("IFramesActive", false)
			end
		end)
	end
	-- Ping-compensated refund. GetNetworkPing is measured server-side, so a client cannot
	-- inflate it to farm heals; the window and the total are capped regardless.
	if cm and cm.refundRecentDamage then
		local ping = 0
		local ok, v = pcall(function() return player:GetNetworkPing() end)
		if ok and type(v) == "number" then ping = v end
		local window = math.min(ping + duration, DODGECFG.MaxRefundWindow)
		cm.refundRecentDamage(player, window, DODGECFG.MaxRefundPerDodge)
	end
end

-- ── Dash ─────────────────────────────────────────────────────────────────
local VALID_DIRS = { forward = true, back = true, left = true, right = true }

-- The dash momentum curve, identical to MovementClient's. Kept as a duplicated four lines
-- rather than shared through a module because every number comes from Config -- there is no
-- state here to drift -- and because the whole point is that the server can compute this
-- WITHOUT trusting the client.
local function dashSpeedFor(speedNow)
	local minS = DASHCFG.MinSpeed or 32
	local maxS = DASHCFG.MaxSpeed or 73
	local top  = math.max(1, MCFG.SprintSpeed or 26)
	return minS + (maxS - minS) * (math.clamp(speedNow / top, 0, 1) ^ (DASHCFG.MomentumCurve or 1.5))
end

-- How fast the player was travelling when the dash went out, resolved without taking the
-- client's word for it. AssemblyLinearVelocity replicates, so we compute our own answer and
-- clamp the client's claim between that and the configured ceiling. An honest client is never
-- snapped back over a stale velocity reading, and a lying one gains at most the legitimate
-- maximum -- i.e. the guard degrades to the flat cap it used to be, never worse.
local function resolveDashSpeed(hrp, claimed)
	local v = hrp.AssemblyLinearVelocity
	local ours = dashSpeedFor(Vector3.new(v.X, 0, v.Z).Magnitude)
	if type(claimed) ~= "number" or claimed ~= claimed then return ours end
	return math.clamp(claimed, ours, DASHCFG.MaxSpeed or 73)
end

-- Every refusal path returns its reason AND tells the client, so a dash never just
-- silently does nothing.
local function denyDash(player, reason, retryAfter)
	RE_DodgeResult:FireClient(player, { result = "denied", reason = reason, retryAfter = retryAfter })
	return "denied:" .. reason
end

local function processDash(player, dirToken, wasGrounded, claimedSpeed)
	local s = getPS(player)
	if not s then return "denied:nostate" end
	if type(dirToken) ~= "string" or not VALID_DIRS[dirToken] then return "denied:baddir" end

	local char, hum, hrp = charParts(player)
	if not hum or not hrp then return "denied:nocharacter" end
	if hum.Health <= 0 then return "denied:dead" end

	local now = os.clock()
	if now < s.dashCooldownUntil then
		return denyDash(player, "cooldown", s.dashCooldownUntil - now)
	end

	-- GROUND ONLY (2026-08-09). The client refuses this too, for instant feedback; this is
	-- the authoritative half. FloorMaterial is checked server-side rather than trusting the
	-- client's wasGrounded flag, which a spoofing client would simply lie about.
	if hum.FloorMaterial == Enum.Material.Air then
		return denyDash(player, "airborne")
	end

	local cm = _G.CombatManager
	if cm and cm.isActionBlocked and cm.isActionBlocked(player) then
		return denyDash(player, "blocked")
	end
	local mm = _G.MovementManager
	if mm and mm.isCrouching and mm.isCrouching(player) then
		return denyDash(player, "crouched")
	end

	-- Resolve the dodge tier BEFORE charging stamina, since fatigued costs more.
	local tier = consumeDodge(player, s)
	local cost = DASHCFG.StaminaCost * (tier == "fatigued" and (DODGECFG.FatiguedStaminaMult or 1.5) or 1)
	local tm = _G.TraitManager
	if tm and tm.getDashCostReduction then
		cost = math.max(0, cost - tm.getDashCostReduction(player))
	end

	local sm = _G.StaminaManager
	-- StaminaManager.drain is all-or-nothing: it returns false and drains NOTHING if you
	-- cannot afford it, so there is no partial-charge case to unwind here.
	if sm and not sm.drain(player, cost) then
		s.dodgeStock = math.min(DODGECFG.MaxStock, s.dodgeStock + (tier == "clean" and 1 or 0)) -- give the stock back
		return denyDash(player, "stamina")
	end

	s.dashCooldownUntil = now + DASHCFG.Cooldown * talentMult(player, "DashCooldownMult")
	s.isDashing   = true
	s.dashEndsAt  = now + DASHCFG.Duration
	s.dashStartPos = hrp.Position
	-- What the client is allowed to have covered by the time the dash ends. Generous on
	-- purpose (1.5x) so a slope, a moving boat deck or a bit of latency never trips it.
	-- The budget now tracks the momentum curve, so a standing dodge is held to a standing
	-- dodge's distance instead of to a sprinting lunge's.
	local speed = resolveDashSpeed(hrp, claimedSpeed)
		* (wasGrounded == false and (DASHCFG.AirForceMult or 0.7) or 1)
	s.dashMaxDist = speed * DASHCFG.Duration * (DASHCFG.MaxDisplacementMult or 1.5)

	local iframes = DODGECFG.IframeDuration * (tier == "fatigued" and (DODGECFG.FatiguedIframeMult or 0.4) or 1)
	grantIframes(player, iframes)

	-- Sprinting through a dash would let the ceiling stay raised while the dash owns the
	-- root; drop it so the exit is a clean run-up rather than an instant re-sprint.
	if s.isSprinting then stopSprint(player, s) end

	RE_DodgeResult:FireClient(player, {
		result = tier, iframes = iframes, stock = s.dodgeStock, dir = dirToken,
	})
	return tier
end

RE_Dash.OnServerEvent:Connect(function(p, dirToken, wasGrounded, claimedSpeed)
	processDash(p, dirToken, wasGrounded, claimedSpeed)
end)

-- ── Slide ────────────────────────────────────────────────────────────────
-- The slide's PHYSICS are the client's (it owns its own character, and a slope-fed slide
-- has to be frame-tight to feel right). The server owns the resource cost and the state
-- other systems read -- same split as the dash.
local SLIDECFG = MCFG.Slide or {}

local function processSlide(player)
	local s = getPS(player)
	if not s or s.isSliding then return end
	local char, hum, hrp = charParts(player)
	if not hum or not hrp or hum.Health <= 0 then return end

	local now = os.clock()
	if now < s.slideCooldownUntil then return end

	local cm = _G.CombatManager
	if cm and cm.isActionBlocked and cm.isActionBlocked(player) then return end
	local mm = _G.MovementManager
	if mm and mm.isCrouching and mm.isCrouching(player) then return end

	-- Server-side speed check: the client already gated on this, but MoveDirection and the
	-- root's velocity both replicate, so we can verify rather than take its word for it.
	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z).Magnitude
	if flat < (SLIDECFG.MinSpeedToSlide or 12) * 0.6 then -- 0.6 slack for latency
		-- SLOPE ALLOWANCE (2026-08-08): slope sliding means a slow entry is legitimate on a
		-- slide-worthy incline (the client seeds it downhill from a standstill). Position
		-- replicates, so verify the slope the same way the client did: raycast under the
		-- root and measure the surface angle.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {char}
		local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -6, 0), params)
		local angle = 0
		if hit then
			angle = math.deg(math.acos(math.clamp(hit.Normal:Dot(Vector3.yAxis), -1, 1)))
		end
		if angle < (SLIDECFG.SlideSlopeAngle or 35) or angle >= (SLIDECFG.MaxSlopeAngle or 60) then
			return
		end
	end

	local sm = _G.StaminaManager
	if sm and not sm.drain(player, SLIDECFG.StaminaCost or 8) then return end

	s.isSliding = true
	if s.isSprinting then stopSprint(player, s) end
	if char then char:SetAttribute("SlideActive", true) end
end

local function endSlide(player)
	local s = getPS(player)
	if not s or not s.isSliding then return end
	s.isSliding = false
	s.slideCooldownUntil = os.clock() + (SLIDECFG.Cooldown or 0.6)
	local char = player.Character
	if char then char:SetAttribute("SlideActive", false) end
end

RE_Slide.OnServerEvent:Connect(function(p) processSlide(p) end)
RE_SlideEnd.OnServerEvent:Connect(function(p) endSlide(p) end)

-- ── Heartbeat: sprint stamina + dash displacement guard ────────────────────────────
RunService.Heartbeat:Connect(function(dt)
	local sm = _G.StaminaManager
	local cm = _G.CombatManager
	local now = os.clock()

	for _, player in ipairs(Players:GetPlayers()) do
		local s = getPS(player)
		if s then
			local char, hum, hrp = charParts(player)
			if hum and hrp then

				if s.isSprinting then
					-- Sprint ends the moment the player stops actually going somewhere.
					-- MoveDirection is replicated, so this is honest server-side state, not a
					-- client claim -- and it means a client that stops firing SprintEnd cannot
					-- keep a free speed boost.
					if hum.MoveDirection.Magnitude < 0.05 or hum.Health <= 0 then
						stopSprint(player, s)
					elseif cm and cm.isActionBlocked and cm.isActionBlocked(player) then
						stopSprint(player, s)
					else
						local drain = (SPRINTCFG.StaminaPerSec or 3) * talentMult(player, "SprintStaminaDrain") * dt
						if sm and not sm.drain(player, drain) then stopSprint(player, s) end
					end
				end

				-- Dash displacement guard. The client owns its own character's physics, so a
				-- modified client could stretch a dash into a teleport. We cannot prevent the
				-- motion, but we can measure it after the fact and snap it back. Horizontal
				-- only -- a dash off a ledge legitimately gains a lot of Y.
				if s.isDashing and now >= s.dashEndsAt then
					s.isDashing = false
					if s.dashStartPos then
						local delta = hrp.Position - s.dashStartPos
						local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
						if flat > s.dashMaxDist then
							local dir = Vector3.new(delta.X, 0, delta.Z).Unit
							local capped = s.dashStartPos + dir * s.dashMaxDist
							hrp.CFrame = CFrame.new(Vector3.new(capped.X, hrp.Position.Y, capped.Z))
								* (hrp.CFrame - hrp.CFrame.Position)
							warn(string.format("[MovementSystem] %s dash overshoot %.1f > %.1f studs -- snapped back",
								player.Name, flat, s.dashMaxDist))
						end
					end
					s.dashStartPos = nil
				end
			end
		end
	end
end)

local function onCharacterAdded(player)
	local s = getPS(player)
	if not s then initState(player.UserId); s = getPS(player) end
	s.isSprinting = false
	s.isDashing = false
	s.isSliding = false
	s.slideCooldownUntil = 0
	s.dashStartPos = nil
	-- Dying mid-cooldown should not leave the fresh character unable to dash.
	s.dashCooldownUntil = 0
	s.dodgeStock = DODGECFG.MaxStock
	s.lastStockRegen = os.clock()
end

local function hookPlayer(player)
	player.CharacterAdded:Connect(function() onCharacterAdded(player) end)
end
Players.PlayerAdded:Connect(hookPlayer)
for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end

-- ── Public surface ────────────────────────────────────────────────────────
-- MovementManager's inert stubs delegate to every one of these automatically -- the seam
-- was built for exactly this, so no existing caller needs rewiring.
local MovementSystem = {}

MovementSystem.isSprinting = function(p) local s = getPS(p); return s ~= nil and s.isSprinting end
MovementSystem.isDashing   = function(p) local s = getPS(p); return s ~= nil and s.isDashing end
MovementSystem.isDashOnCooldown = function(p) local s = getPS(p); return s ~= nil and os.clock() < s.dashCooldownUntil end
MovementSystem.canSprint   = function(p) return canSprint(p) end
MovementSystem.startSprint = function(p) return startSprint(p) end
MovementSystem.stopSprint  = function(p) stopSprint(p) end
-- Returns "clean" | "fatigued" | "denied:<reason>" so callers (and the harness) can tell
-- refusals apart instead of inferring from a silent no-op.
MovementSystem.dash        = function(p, dirToken) return processDash(p, dirToken or "forward", true, nil) end
MovementSystem.getDodgeStock = function(p)
	local s = getPS(p); if not s then return 0 end
	regenStock(s); return s.dodgeStock
end

-- Flow: walkPower, published by MovementClient onto the character every frame. Exposed here
-- so the combat revamp can read it server-side without knowing the attribute name.
-- Derived from the root's own velocity, NOT from the `Flow` character attribute MovementClient
-- publishes: attributes set on a client never replicate, so up here that attribute is
-- permanently nil and this used to return 0 for every player, forever.
--
-- Humanoid.MoveDirection is the obvious-looking alternative and it is WRONG: the engine
-- normalises it, so it reads exactly 1.000 whatever magnitude you passed to Move() (measured:
-- Move(0.25) still replicates MoveDirection.Magnitude = 1.000, while the character genuinely
-- travels at 3.97 studs/s). It carries direction only, never momentum.
--
-- AssemblyLinearVelocity does replicate and does carry the magnitude, so flat speed over the
-- authorised ceiling recovers Flow directly. It reports ACHIEVED rather than COMMANDED
-- momentum -- a player shoved against a wall reads 0 -- which for a combat signal is the more
-- honest of the two anyway.
MovementSystem.getFlow = function(p)
	local char = p and p.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	local hrp  = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp then return 0 end
	local v = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(v.X, 0, v.Z).Magnitude
	return math.clamp(flat / math.max(1, hum.WalkSpeed), 0, 1)
end

MovementSystem.isSliding        = function(p) local s = getPS(p); return s ~= nil and s.isSliding end
-- Slide-jump (launching out of a slide) was a separate old mechanic and has not been
-- rebuilt; answer honestly rather than pretending.
MovementSystem.consumeSlideJump = function() return false end
MovementSystem.getMomentum      = function(p) return MovementSystem.getFlow(p) * 100 end

_G.MovementSystem = MovementSystem

print(string.format(
	"[MovementSystem] Pass 2 live -- sprint %d->%d | dash %.1f-%.1f studs (%.2fs) | dodge stock %d @ %.1fs | iframes %.2fs",
	MCFG.BaseWalkSpeed, MCFG.SprintSpeed,
	(DASHCFG.MinSpeed or 32) * DASHCFG.Duration, (DASHCFG.MaxSpeed or 73) * DASHCFG.Duration,
	DASHCFG.Duration, DODGECFG.MaxStock, DODGECFG.RegenTime, DODGECFG.IframeDuration))
