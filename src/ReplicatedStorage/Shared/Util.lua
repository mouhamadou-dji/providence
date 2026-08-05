local Util = {}

function Util.weightedRandom(pool)
    local total = 0
    for _, entry in ipairs(pool) do
        total += entry.weight
    end
    local roll = math.random(1, total)
    local cumulative = 0
    for _, entry in ipairs(pool) do
        cumulative += entry.weight
        if roll <= cumulative then
            return entry.value
        end
    end
    return pool[#pool].value
end

function Util.deepCopy(original)
    local copy = {}
    for k, v in pairs(original) do
        copy[k] = (type(v) == "table") and Util.deepCopy(v) or v
    end
    return copy
end

function Util.mergeDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            target[k] = (type(v) == "table") and Util.deepCopy(v) or v
        elseif type(v) == "table" and type(target[k]) == "table" then
            Util.mergeDefaults(target[k], v)
        end
    end
    return target
end

function Util.generateGUID()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end)
end

function Util.getScaledValue(baseValue, statValue, perPoint)
    return baseValue + (baseValue * (statValue * perPoint))
end

return Util