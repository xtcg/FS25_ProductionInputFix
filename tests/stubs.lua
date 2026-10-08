-- Minimal stand-ins for the engine pieces the base production loop and the fix touch.

LOG = {}
local function logger(level)
    return function(fmt, ...) LOG[#LOG + 1] = level .. ": " .. string.format(fmt, ...) end
end
Logging = { info = logger("info"), warning = logger("warning"), error = logger("error") }

function math.clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
function table.clear(t) for k in pairs(t) do t[k] = nil end end

Utils = {}
function Utils.overwrittenFunction(old, new)
    return function(self, ...) return new(self, old, ...) end
end

g_time = 0
g_currentModName = "FS25_ProductionInputFix"
g_currentMission = { environment = { timeAdjustment = 1 } }
g_fillTypeManager = { getFillTypeNameByIndex = function(_, i) return tostring(i) end }
COMMANDS = {}
function addConsoleCommand(name, _, func, target) COMMANDS[name] = function() return target[func](target) end end

ProductionPointProductionStatusEvent = { sendEvent = function() end }

ProductionPoint = { PROD_STATUS = { INACTIVE = 0, RUNNING = 1, MISSING_INPUTS = 2, NO_OUTPUT_SPACE = 3 } }
ProductionPoint.__index = ProductionPoint
ProductionChainManager = {}
ProductionChainManager.__index = ProductionChainManager

load(BASE_CODE)()

-- storage that clamps like Storage:setFillLevel
local Storage = {}
Storage.__index = Storage
function Storage:getFillLevel(t) return self.levels[t] or 0 end
function Storage:getCapacity(t) return self.caps[t] or 0 end
function Storage:getFreeCapacity(t) return math.max(0, (self.caps[t] or 0) - (self.levels[t] or 0)) end
function Storage:setFillLevel(v, t) self.levels[t] = math.clamp(v, 0, self.caps[t] or 0) end

--- One production point. productions = { {id, cph, inputs = {{type, amount}}, outputs = {{type, amount, sellDirectly}}} }
function newPoint(def)
    local storage = setmetatable({ levels = {}, caps = {} }, Storage)
    for t, c in pairs(def.caps) do storage.caps[t] = c end
    for t, v in pairs(def.levels or {}) do storage.levels[t] = v end
    local pp = setmetatable({
        storage = storage, isOwned = true, isServer = true, inputFillLevels = {},
        productionCostsToClaim = 0, soldFillTypesToPayOut = {}, palletSpawnCooldown = math.huge,
        sharedThroughputCapacity = def.shared or false,
        minuteFactorTimescaled = (def.timeScale or 1) / 1000 / 60,
        outputFillTypeIds = {}, activeProductions = {}, statuses = {},
        owningPlaceable = { productionStatusChanged = function() end },
        name = def.name or "pp",
    }, ProductionPoint)
    pp.getFillLevel = function(self, t) return self.storage:getFillLevel(t) end
    pp.getName = function(self) return self.name end
    pp.setProductionStatus = function(self, id, status) self.statuses[id] = status end
    for _, p in ipairs(def.productions) do
        local prod = { id = p.id, cyclesPerMinute = p.cph / 60, costsPerActiveMinute = 1 / 60, inputs = {}, outputs = {}, status = 0 }
        for _, i in ipairs(p.inputs) do table.insert(prod.inputs, { type = i[1], amount = i[2] }) end
        for _, o in ipairs(p.outputs) do
            table.insert(prod.outputs, { type = o[1], amount = o[2], sellDirectly = o[3] or false })
            pp.outputFillTypeIds[o[1]] = true
            pp.soldFillTypesToPayOut[o[1]] = 0
        end
        table.insert(pp.activeProductions, prod)
    end
    return pp
end

function newManager(points)
    return setmetatable({ productionPoints = points, currentUpdateIndex = 1, isServer = true }, ProductionChainManager)
end

--- Runs `updates` chain-manager frames, each `frameMs` real ms apart. A manager with one
-- point updates it every frame; dt seen by the point = frameMs.
function runFrames(manager, updates, frameMs, beforeEach)
    for _, pp in ipairs(manager.productionPoints) do pp.lastUpdatedTime = g_time end
    for i = 1, updates do
        g_time = g_time + frameMs
        if beforeEach then beforeEach(i) end
        manager:update()
    end
end

RESULTS = {}
function test(name, fn)
    local ok, msg = pcall(fn)
    table.insert(RESULTS, { name = name, ok = ok, msg = msg })
end
function near(a, b, tol, what)
    if math.abs(a - b) > (tol or 1e-3) then
        error(string.format("%s: expected %.6f, got %.6f", what or "value", b, a), 2)
    end
end
function check(cond, what) if not cond then error(what or "check failed", 2) end end
function logContains(text)
    for _, line in ipairs(LOG) do
        if line:find(text, 1, true) then return true end
    end
    return false
end
