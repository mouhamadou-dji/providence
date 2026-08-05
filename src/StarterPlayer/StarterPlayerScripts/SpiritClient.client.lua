-- SpiritClient.client.lua
-- Gates spirit visibility on the Talent_AwakenedEyes character attribute (mirrored by
-- TalentManager). LocalTransparencyModifier/Enabled toggles here are purely local-client
-- rendering overrides -- they never replicate to other clients or the server, which is
-- exactly the per-player visibility the spec asks for ("only visible to Awakened players").
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")

local localPlayer = Players.LocalPlayer
local SPIRIT_TAG = "ABYSSSpirit"

local function hasAwakenedEyes()
    local char = localPlayer.Character
    return char ~= nil and char:GetAttribute("Talent_AwakenedEyes") == true
end

local function applyVisibility(part)
    if not part or not part.Parent then return end
    local visible = hasAwakenedEyes()
    part.LocalTransparencyModifier = visible and 0 or 1
    local light = part:FindFirstChildOfClass("PointLight")
    if light then light.Enabled = visible end
    local pe = part:FindFirstChildOfClass("ParticleEmitter")
    if pe then pe.Enabled = visible end
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if prompt then prompt.Enabled = visible end
end

local function refreshAll()
    for _, part in ipairs(CollectionService:GetTagged(SPIRIT_TAG)) do
        applyVisibility(part)
    end
end

for _, part in ipairs(CollectionService:GetTagged(SPIRIT_TAG)) do
    applyVisibility(part)
end
CollectionService:GetInstanceAddedSignal(SPIRIT_TAG):Connect(applyVisibility)

local function hookCharacter(char)
    char:GetAttributeChangedSignal("Talent_AwakenedEyes"):Connect(refreshAll)
    task.wait(0.5) -- let TalentManager's mirrorTalentAttributes land on the fresh character
    refreshAll()
end

localPlayer.CharacterAdded:Connect(hookCharacter)
if localPlayer.Character then hookCharacter(localPlayer.Character) end

print("[SpiritClient] Loaded")
