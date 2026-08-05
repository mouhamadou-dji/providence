-- DiscordManager — Module 15
-- Webhook integration for all loggable server events

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")

local WEBHOOK_URL = "PLACEHOLDER_WEBHOOK_URL"  -- PLACEHOLDER_WEBHOOK: replace before going live

-- ── Rate limiting ─────────────────────────────────────────────────────────────
local RATE_MAX    = 5   -- max messages per window
local RATE_WINDOW = 10  -- seconds

local messageTimestamps = {}

local function checkRateLimit()
    local now = tick()
    local i = 1
    while i <= #messageTimestamps do
        if now - messageTimestamps[i] > RATE_WINDOW then
            table.remove(messageTimestamps, i)
        else
            i += 1
        end
    end
    if #messageTimestamps >= RATE_MAX then
        warn("[DiscordManager] Rate limited — message dropped")
        return false
    end
    table.insert(messageTimestamps, now)
    return true
end

-- ── Category colors (decimal) ─────────────────────────────────────────────────
local COLORS = {
    MOD_ACTION       = 3447003,   -- blue
    PDE_DEATH        = 10027008,  -- red
    ZONE_DISCOVERY   = 3066993,   -- green
    QTE_RESULT       = 16705372,  -- yellow
    STAGE_CHANGE     = 10181046,  -- purple
    ECONOMY          = 15844367,  -- gold
    SERVER           = 9807270,   -- gray
    GLOBAL_MESSAGE   = 15921906,  -- white
    PLAYER_JOIN_LEAVE = 3066993,  -- green
    MEDITATION       = 8359053,   -- soft blue
    PUSHUPS          = 15105570,  -- orange
    SPIRIT           = 10181046,  -- purple (matches STAGE_CHANGE, both "otherworldly")
    INTERACTABLE     = 3447003,   -- blue (matches MOD_ACTION)
    NPC              = 10181046,  -- purple
    BTOOL            = 3447003,   -- blue (matches MOD_ACTION)
    INJURY           = 10027008,  -- red (matches PDE_DEATH, both bodily-harm categories)
    DNA              = 10181046,  -- purple (matches STAGE_CHANGE/SPIRIT, lore-system category)
    RITUAL           = 10181046,  -- purple
    POTION           = 3066993,   -- green (matches ZONE_DISCOVERY, benign player action)
    SANITY           = 9807270,   -- gray (matches SERVER, quiet/frequent background category)
    RAGE             = 10027008,  -- red (matches PDE_DEATH, dramatic state change)
    ALLY             = 15921906,  -- white (matches GLOBAL_MESSAGE)
    FEELING          = 9807270,   -- gray (matches SANITY, quiet/frequent background category)
}

-- ── Test mode ─────────────────────────────────────────────────────────────────
local testMode    = false
local lastPayload = nil

-- ── Core send ─────────────────────────────────────────────────────────────────
local function send(category, title, description, color)
    if not checkRateLimit() then return false end

    local payload = {
        embeds = {{
            title       = "[" .. category .. "] " .. tostring(title),
            description = tostring(description),
            color       = color or COLORS[category] or 10027008,
            timestamp   = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }}
    }

    lastPayload = {
        category    = category,
        title       = title,
        description = description,
        color       = color or COLORS[category] or 10027008,
        payload     = payload,
    }

    if testMode then
        print(string.format("[DiscordManager] (TEST) [%s] %s", category, title))
        return true
    end

    local success, err = pcall(function()
        HttpService:PostAsync(
            WEBHOOK_URL,
            HttpService:JSONEncode(payload),
            Enum.HttpContentType.ApplicationJson
        )
    end)

    if success then
        print(string.format("[DiscordManager] Sent [%s] %s", category, title))
    else
        warn(string.format("[DiscordManager] Webhook failed [%s]: %s", category, tostring(err)))
    end

    return success
end

-- ── Public API ────────────────────────────────────────────────────────────────
local DiscordManager = {}

function DiscordManager.setTestMode(enabled)
    testMode = enabled == true
end

function DiscordManager.getLastPayload()
    return lastPayload
end

function DiscordManager.clearRateLimit()
    messageTimestamps = {}
end

function DiscordManager.logModAction(executer, command, result)
    local name = executer and executer.Name or "SYSTEM"
    send("MOD_ACTION",
        name .. " ran: " .. tostring(command),
        "Result: " .. tostring(result),
        COLORS.MOD_ACTION)
end

function DiscordManager.logPDEDeath(player, zoneName)
    send("PDE_DEATH",
        player.Name .. " — Permanent Death",
        "Zone: " .. tostring(zoneName) .. "\nCharacter data wiped.",
        COLORS.PDE_DEATH)
end

function DiscordManager.logZoneDiscovery(player, zoneName, stage)
    send("ZONE_DISCOVERY",
        player.Name .. " discovered: " .. tostring(zoneName),
        "PD Stage at discovery: " .. tostring(stage),
        COLORS.ZONE_DISCOVERY)
end

function DiscordManager.logQTEResult(player, success, context)
    send("QTE_RESULT",
        player.Name .. " QTE: " .. (success and "SUCCESS" or "FAIL"),
        "Context: " .. tostring(context),
        COLORS.QTE_RESULT)
end

function DiscordManager.logStageChange(player, oldStage, newStage)
    send("STAGE_CHANGE",
        player.Name .. " Stage: " .. tostring(oldStage) .. " → " .. tostring(newStage),
        "PD progression recorded.",
        COLORS.STAGE_CHANGE)
end

function DiscordManager.logEconomy(executer, player, currencyType, amount, isGrant)
    local name   = executer and executer.Name or "SYSTEM"
    local action = isGrant and "GRANT" or "REVOKE"
    send("ECONOMY",
        name .. " " .. action .. ": " .. tostring(amount) .. " " .. tostring(currencyType),
        "To: " .. player.Name,
        COLORS.ECONOMY)
end

function DiscordManager.logServer(event, details)
    send("SERVER",
        "Server: " .. tostring(event),
        tostring(details),
        COLORS.SERVER)
end

function DiscordManager.logGlobalMessage(executer, message)
    local name = executer and executer.Name or "SYSTEM"
    send("GLOBAL_MESSAGE",
        name .. " sent global message",
        tostring(message),
        COLORS.GLOBAL_MESSAGE)
end

function DiscordManager.logPlayerJoinLeave(player, isJoining)
    send("PLAYER_JOIN_LEAVE",
        player.Name .. (isJoining and " joined" or " left") .. " the server",
        "UserId: " .. tostring(player.UserId),
        COLORS.PLAYER_JOIN_LEAVE)
end

function DiscordManager.logMeditation(player, event, details)
    send("MEDITATION",
        player.Name .. " meditation: " .. tostring(event),
        tostring(details),
        COLORS.MEDITATION)
end

function DiscordManager.logPushups(player, event, details)
    send("PUSHUPS",
        player.Name .. " pushups: " .. tostring(event),
        tostring(details),
        COLORS.PUSHUPS)
end

function DiscordManager.logSpiritInteraction(player, faction, rep, position)
    send("SPIRIT",
        player.Name .. " interacted with a " .. tostring(faction) .. " Spirit",
        string.format("Rep: %d | Pos: (%.0f, %.0f, %.0f)", rep or 0,
            position and position.X or 0, position and position.Y or 0, position and position.Z or 0),
        COLORS.SPIRIT)
end

function DiscordManager.logInteractable(player, interactableName, details)
    send("INTERACTABLE",
        player.Name .. " -> " .. tostring(interactableName),
        tostring(details),
        COLORS.INTERACTABLE)
end

function DiscordManager.logNPC(event, details)
    send("NPC",
        "NPC " .. tostring(event),
        tostring(details),
        COLORS.NPC)
end

function DiscordManager.logBTool(charName, details)
    send("BTOOL",
        tostring(charName) .. " used a BTool",
        tostring(details),
        COLORS.BTOOL)
end

function DiscordManager.logInjury(charName, details)
    send("INJURY",
        tostring(charName) .. " injury update",
        tostring(details),
        COLORS.INJURY)
end

function DiscordManager.logDNA(charName, details)
    send("DNA",
        tostring(charName) .. " DNA update",
        tostring(details),
        COLORS.DNA)
end

function DiscordManager.logRitual(charName, details)
    send("RITUAL",
        tostring(charName) .. " ritual event",
        tostring(details),
        COLORS.RITUAL)
end

function DiscordManager.logPotion(charName, details)
    send("POTION",
        tostring(charName) .. " used a potion",
        tostring(details),
        COLORS.POTION)
end

function DiscordManager.logSanity(charName, details)
    send("SANITY",
        tostring(charName) .. " sanity update",
        tostring(details),
        COLORS.SANITY)
end

function DiscordManager.logRage(charName, details)
    send("RAGE",
        tostring(charName) .. " rage event",
        tostring(details),
        COLORS.RAGE)
end

function DiscordManager.logAlly(charName, details)
    send("ALLY",
        tostring(charName) .. " ally event",
        tostring(details),
        COLORS.ALLY)
end

_G.DiscordManager = DiscordManager

-- ── Auto-hooks ────────────────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player)
    DiscordManager.logPlayerJoinLeave(player, true)
end)
Players.PlayerRemoving:Connect(function(player)
    DiscordManager.logPlayerJoinLeave(player, false)
end)

-- Log server start
DiscordManager.logServer("SERVER_START", "ABYSS server initialized")

local configured = WEBHOOK_URL ~= "PLACEHOLDER_WEBHOOK_URL"
print("[DiscordManager] Init — webhook: " .. (configured and "configured" or "PLACEHOLDER") ..
    " | rate: " .. RATE_MAX .. "/" .. RATE_WINDOW .. "s")
