-- Discord_TestHarness — DiscordManager tests
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end -- test harness: Studio-only, never runs in a live published server

local function waitFor(name, timeout)
    local t = tick() + (timeout or 10)
    while not _G[name] do
        if tick() > t then return nil end
        task.wait(0.05)
    end
    return _G[name]
end

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then print("[DM_TEST] PASS: " .. name); passed += 1
    else warn("[DM_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[DM_TEST] No player"); return end

local Discord = waitFor("DiscordManager", 10)
if not Discord then warn("[DM_TEST] DiscordManager not ready"); return end
local MM = waitFor("ModManager", 8)
if not MM then warn("[DM_TEST] ModManager not ready"); return end
local DM = waitFor("DataManager", 8)
if not DM then warn("[DM_TEST] DataManager not ready"); return end

local deadline = tick() + 6
while DM.getValue(player, "PlayerState") == nil and tick() < deadline do task.wait(0.1) end
if DM.getValue(player, "PlayerState") == nil then
    warn("[DM_TEST] DataManager not ready — aborting"); return
end

print("[DM_TEST] Starting DiscordManager tests — player: " .. player.Name)

-- Enable test mode so no actual HTTP calls are made, then clear rate limit
Discord.setTestMode(true)
Discord.clearRateLimit()

-- T1: DiscordManager exists with all expected functions
test("T1_DiscordManagerExists", function()
    assert(_G.DiscordManager ~= nil,                       "DiscordManager not in _G")
    assert(type(Discord.logModAction)       == "function", "logModAction missing")
    assert(type(Discord.logPDEDeath)        == "function", "logPDEDeath missing")
    assert(type(Discord.logZoneDiscovery)   == "function", "logZoneDiscovery missing")
    assert(type(Discord.logQTEResult)       == "function", "logQTEResult missing")
    assert(type(Discord.logStageChange)     == "function", "logStageChange missing")
    assert(type(Discord.logEconomy)         == "function", "logEconomy missing")
    assert(type(Discord.logServer)          == "function", "logServer missing")
    assert(type(Discord.logGlobalMessage)   == "function", "logGlobalMessage missing")
    assert(type(Discord.logPlayerJoinLeave) == "function", "logPlayerJoinLeave missing")
    assert(type(Discord.setTestMode)        == "function", "setTestMode missing")
    assert(type(Discord.getLastPayload)     == "function", "getLastPayload missing")
    assert(type(Discord.clearRateLimit)     == "function", "clearRateLimit missing")
end)

-- T2: logModAction captures correct category and payload in test mode
test("T2_LogModAction", function()
    Discord.clearRateLimit()
    Discord.logModAction(player, "setStage", "OK")
    local p = Discord.getLastPayload()
    assert(p ~= nil,                          "getLastPayload should return data")
    assert(p.category == "MOD_ACTION",        "category should be MOD_ACTION, got: " .. tostring(p.category))
    assert(p.title:find(player.Name),         "title should contain player name")
    assert(p.title:find("setStage"),          "title should mention command")
    assert(p.description:find("OK"),          "description should contain result")
    assert(p.payload.embeds ~= nil,           "payload should have embeds")
    assert(p.payload.embeds[1].timestamp ~= nil, "embed should have timestamp")
end)

-- T3: logPDEDeath captures correct category
test("T3_LogPDEDeath", function()
    Discord.clearRateLimit()
    Discord.logPDEDeath(player, "TestZone")
    local p = Discord.getLastPayload()
    assert(p.category == "PDE_DEATH",   "category should be PDE_DEATH")
    assert(p.title:find(player.Name),   "title should have player name")
    assert(p.description:find("TestZone"), "description should have zone name")
end)

-- T4: logZoneDiscovery captures stage
test("T4_LogZoneDiscovery", function()
    Discord.clearRateLimit()
    Discord.logZoneDiscovery(player, "IronHollow", 2)
    local p = Discord.getLastPayload()
    assert(p.category == "ZONE_DISCOVERY", "category should be ZONE_DISCOVERY")
    assert(p.description:find("2"),        "description should contain stage 2")
end)

-- T5: logStageChange captures old and new stage
test("T5_LogStageChange", function()
    Discord.clearRateLimit()
    Discord.logStageChange(player, 1, 2)
    local p = Discord.getLastPayload()
    assert(p.category == "STAGE_CHANGE", "category should be STAGE_CHANGE")
    assert(p.title:find("1"),            "title should contain old stage 1")
    assert(p.title:find("2"),            "title should contain new stage 2")
end)

-- T6: logEconomy grant captures correct fields
test("T6_LogEconomyGrant", function()
    Discord.clearRateLimit()
    Discord.logEconomy(player, player, "Obol", 100, true)
    local p = Discord.getLastPayload()
    assert(p.category == "ECONOMY",      "category should be ECONOMY")
    assert(p.title:find("GRANT"),        "title should say GRANT")
    assert(p.title:find("100"),          "title should contain amount")
    assert(p.title:find("Obol"),         "title should contain currency type")
end)

-- T7: logEconomy revoke uses REVOKE label
test("T7_LogEconomyRevoke", function()
    Discord.clearRateLimit()
    Discord.logEconomy(nil, player, "Drachma", 50, false)
    local p = Discord.getLastPayload()
    assert(p.category == "ECONOMY",  "category should be ECONOMY")
    assert(p.title:find("REVOKE"),   "title should say REVOKE for revoke action")
end)

-- T8: logGlobalMessage captures message text
test("T8_LogGlobalMessage", function()
    Discord.clearRateLimit()
    Discord.logGlobalMessage(player, "Server is restarting in 5 minutes")
    local p = Discord.getLastPayload()
    assert(p.category == "GLOBAL_MESSAGE",                "category should be GLOBAL_MESSAGE")
    assert(p.description:find("restarting"),              "description should contain message text")
end)

-- T9: logServer captures event and details
test("T9_LogServer", function()
    Discord.clearRateLimit()
    Discord.logServer("SERVER_LOCK", "Server locked by owner")
    local p = Discord.getLastPayload()
    assert(p.category == "SERVER",              "category should be SERVER")
    assert(p.description:find("locked"),        "description should contain details")
end)

-- T10: logPlayerJoinLeave join
test("T10_LogPlayerJoin", function()
    Discord.clearRateLimit()
    Discord.logPlayerJoinLeave(player, true)
    local p = Discord.getLastPayload()
    assert(p.category == "PLAYER_JOIN_LEAVE",  "category should be PLAYER_JOIN_LEAVE")
    assert(p.title:find("joined"),             "title should say joined")
    assert(p.title:find(player.Name),          "title should have player name")
end)

-- T11: logPlayerJoinLeave leave
test("T11_LogPlayerLeave", function()
    Discord.clearRateLimit()
    Discord.logPlayerJoinLeave(player, false)
    local p = Discord.getLastPayload()
    assert(p.category == "PLAYER_JOIN_LEAVE", "category should be PLAYER_JOIN_LEAVE")
    assert(p.title:find("left"),              "title should say left for disconnect")
end)

-- T12: Rate limiting blocks messages beyond RATE_MAX (5 per 10s)
test("T12_RateLimiting", function()
    Discord.clearRateLimit()
    local successes = 0
    for i = 1, 6 do
        local result = Discord.logServer("RATE_TEST_" .. i, "message " .. i)
        if Discord.getLastPayload() and Discord.getLastPayload().title:find("RATE_TEST_" .. i) then
            successes += 1
        end
    end
    assert(successes <= 5,
        "Should not have more than 5 successes within rate window, got: " .. successes)
    assert(successes >= 4,
        "Should have at least 4 successes before rate limit, got: " .. successes)
end)

-- T13: Graceful failure when webhook is PLACEHOLDER (not test mode, URL is wrong)
test("T13_GracefulWebhookFailure", function()
    Discord.setTestMode(false)
    Discord.clearRateLimit()
    local ok = pcall(function()
        Discord.logServer("TEST_GRACEFUL", "Testing graceful failure")
    end)
    assert(ok == true, "logServer should not throw even when webhook fails")
    Discord.setTestMode(true)  -- restore test mode
    Discord.clearRateLimit()
end)

-- T14: Integration — ModManager directExecute calls DiscordManager.logModAction
test("T14_ModManagerIntegration", function()
    Discord.clearRateLimit()
    local lm = _G.LoreManager
    if lm then lm.setStage(player, 0) end
    MM.directExecute("setStage", nil, player, 1)
    local p = Discord.getLastPayload()
    assert(p ~= nil,                       "DiscordManager should have received a payload")
    assert(p.category == "MOD_ACTION",
        "Last payload should be MOD_ACTION from ModManager, got: " .. tostring(p.category))
    assert(p.title:find("setStage"),       "Payload title should mention setStage")
    if lm then lm.setStage(player, 0) end
end)

Discord.setTestMode(false)  -- restore before done
print(string.format("[DM_TEST] Done — %d pass / %d fail", passed, failed))
