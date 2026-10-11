-- ProductionInputFix
--
-- Base game ProductionPoint:updateProduction checks whether the inputs cover
-- one step at real-time speed:
--     fillLevel < amount * cyclesPerMinute * (dt / 60000 * timeAdjust)
-- but consumes and produces that step at game speed (times the time scale):
--     amount * cyclesPerMinute * dt * minuteFactorTimescaled * timeAdjust
-- Storage clamps the input at 0, so whenever an input holds less than one step
-- but more than 1/timeScale of it, the full step's output appears. Productions
-- with high cyclesPerHour (cream 4000/h, calf milk 2000/h, milking carousel
-- 12000/h on Hof Bergmann) turn 100 L into several hundred litres.
--
-- Fix: after map wrappers refill inputs, each recipe is limited when the base
-- loop reads its rate, using live stock left by preceding recipes. Its cyclesPerMinute is scaled so
-- the step uses at most what the inputs hold and the outputs can take. The
-- value is restored right after. The base loop and every wrapper a map or mod
-- put around updateProduction run unchanged.

ProductionInputFix = {}
ProductionInputFix.MOD_NAME = g_currentModName
ProductionInputFix.enabled = true
ProductionInputFix.MARGIN = 0.999999 -- keep the scaled step just below the stock so float rounding never trips the base check
ProductionInputFix.stats = {}

-- Limit one recipe using the live stock left by the preceding recipe.
local function limitProduction(point, production, divisor, cycles)
    local dt = math.clamp(g_time - point.lastUpdatedTime, 0, 30000)
    local environment = g_currentMission ~= nil and g_currentMission.environment
    local adjust = environment ~= nil and environment.timeAdjustment or 1
    local step = cycles * dt * (point.minuteFactorTimescaled or 0) * adjust
    local realStep = cycles * dt / 60000 * adjust
    local factor, inputLimited, baseWouldPass = 1, false, true
    local wasUpdating = point.updatingProduction
    point.updatingProduction = true
    for _, input in ipairs(production.inputs) do
        local level = point:getFillLevel(input.type) or 0
        local checked = input.amount * realStep
        local need = math.max(input.amount * step / divisor, checked)
        if level < checked then baseWouldPass = false end
        if need > 0 and level < need then
            factor = math.min(factor, level / need)
            inputLimited = true
        end
    end
    for _, output in ipairs(production.outputs) do
        if not output.sellDirectly then
            local need = output.amount * step
            local space = point.storage:getFreeCapacity(output.type) or 0
            if need > 0 and space < need then
                factor = math.min(factor, space / need)
                baseWouldPass = false
            end
        end
    end
    point.updatingProduction = wasUpdating
    -- At zero stock/space the original base check blocks this recipe. Any
    -- positive stock, however small, must be limited rather than left at full speed.
    if not inputLimited and factor < 1e-6 then return cycles end
    if factor > 0 and factor < 1 then
        factor = factor * ProductionInputFix.MARGIN
        if inputLimited and baseWouldPass then
            ProductionInputFix.recordWithheld(point, production, step / divisor * (1 - factor))
        end
        return cycles * factor
    end
    return cycles
end

--- The base loop reads cyclesPerMinute just before calculating each recipe's
-- step. Resolve that rate lazily against live stock, keeping activeProductions
-- itself untouched so HB's enumeration, autoOff removal and activation persist.
function ProductionInputFix.limitSteps(point)
    if not ProductionInputFix.enabled or point == nil or not point.isOwned
        or point.lastUpdatedTime == nil then return nil end
    if point.pifStepView ~= nil then return nil end
    local productions = point.activeProductions
    if productions == nil or #productions == 0 then return nil end
    local state = { point = point, entries = {} }
    local divisor = point.sharedThroughputCapacity and #productions or 1
    local seen = {}
    local function wrapProduction(production)
        if seen[production] then return end
        seen[production] = true
        local originalMetatable = getmetatable(production)
        local entry = { production = production, metatable = originalMetatable,
            rawRate = rawget(production, "cyclesPerMinute"), rate = production.cyclesPerMinute or 0 }
        local view = {}
        for key, value in pairs(originalMetatable or {}) do view[key] = value end
        local originalIndex = view.__index
        view.__index = function(self, key)
            if key == "cyclesPerMinute" then
                if not entry.resolved then
                    -- Mark first so a diagnostic callback reading the rate cannot recurse.
                    entry.resolved = true
                    entry.rate = limitProduction(point, self, divisor, entry.rate)
                end
                return entry.rate
            end
            if type(originalIndex) == "function" then return originalIndex(self, key) end
            if originalIndex ~= nil then return originalIndex[key] end
        end
        state.entries[#state.entries + 1] = entry
        setmetatable(production, view)
        rawset(production, "cyclesPerMinute", nil)
    end
    -- setProductionState can activate an initially inactive recipe after autoOff
    -- shifts the array, and the base loop may reach it in this same update.
    -- Cover every registered recipe, resolving its rate only if it is read.
    -- Deduplicate the registries so each field/metatable has one restore entry.
    for _, production in ipairs(productions) do wrapProduction(production) end
    for _, production in pairs(point.productions or {}) do wrapProduction(production) end
    for _, production in pairs(point.productionsIdToObj or {}) do wrapProduction(production) end
    point.pifStepView = state
    return state
end

function ProductionInputFix.restore(state)
    if state == nil then return end
    for _, entry in ipairs(state.entries) do
        rawset(entry.production, "cyclesPerMinute", entry.rawRate)
        setmetatable(entry.production, entry.metatable)
    end
    state.point.pifStepView = nil
end

--- Counts output the unfixed game would have created from nothing.
function ProductionInputFix.recordWithheld(productionPoint, production, cycles)
    local name = productionPoint.getName ~= nil and productionPoint:getName() or "?"
    local key = string.format("%s / %s", tostring(name), tostring(production.id))
    local stat = ProductionInputFix.stats[key]

    if stat == nil then
        stat = {steps = 0, outputs = {}}
        ProductionInputFix.stats[key] = stat
    end

    stat.steps = stat.steps + 1
    for _, output in ipairs(production.outputs) do
        stat.outputs[output.type] = (stat.outputs[output.type] or 0) + output.amount * cycles
    end
end

-- Hook the base loop, not the chain manager: map/subclass/instance wrappers
-- must finish their pre-update input transfers before we inspect the stock.
function ProductionInputFix.updateProduction(productionPoint, superFunc, ...)
    local changed = ProductionInputFix.limitSteps(productionPoint)
    if changed == nil then
        return superFunc(productionPoint, ...)
    end

    local result = table.pack(pcall(superFunc, productionPoint, ...))
    ProductionInputFix.restore(changed)

    if not result[1] then
        error(result[2], 0)
    end
    return table.unpack(result, 2, result.n)
end

-- HB can capture the original base function while its specialization scripts
-- load, before this mod loads. Its refill wrapper calls updateAutoFillInputs
-- immediately before that captured base loop. Intercept that boundary for the
-- duration of this manager update, then remove the temporary instance method.
function ProductionInputFix.chainManagerUpdate(manager, superFunc, ...)
    local points = manager.productionPoints
    local count = points ~= nil and #points or 0
    local index = manager.currentUpdateIndex or 1
    if index > count then index = 1 end
    local point = points ~= nil and points[index] or nil
    if point == nil or point.updateAutoFillInputs == nil then
        return superFunc(manager, ...)
    end

    local refill = point.updateAutoFillInputs
    local ownRefill = rawget(point, "updateAutoFillInputs")
    local changed
    point.updateAutoFillInputs = function(self, ...)
        -- HB also refills after production; it must see the configured rate.
        ProductionInputFix.restore(changed)
        changed = nil
        local result = table.pack(refill(self, ...))
        changed = ProductionInputFix.limitSteps(self)
        return table.unpack(result, 1, result.n)
    end

    local result = table.pack(pcall(superFunc, manager, ...))
    ProductionInputFix.restore(changed)
    point.updateAutoFillInputs = ownRefill
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
end

function ProductionInputFix.consoleInfo()
    local lines = {string.format("ProductionInputFix: %s", ProductionInputFix.enabled and "enabled" or "DISABLED")}
    local keys = {}

    for key in pairs(ProductionInputFix.stats) do
        table.insert(keys, key)
    end
    table.sort(keys)

    for _, key in ipairs(keys) do
        local stat = ProductionInputFix.stats[key]
        local parts = {}
        for fillType, amount in pairs(stat.outputs) do
            local fillTypeName = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeNameByIndex(fillType) or tostring(fillType)
            table.insert(parts, string.format("%s %.0f", tostring(fillTypeName), amount))
        end
        table.sort(parts)
        table.insert(lines, string.format("  %s: %d steps limited, not created: %s", key, stat.steps, table.concat(parts, ", ")))
    end

    if #keys == 0 then
        table.insert(lines, "  no step limited since load")
    end

    return table.concat(lines, "\n")
end

function ProductionInputFix.consoleToggle()
    ProductionInputFix.enabled = not ProductionInputFix.enabled
    return string.format("ProductionInputFix: %s", ProductionInputFix.enabled and "enabled" or "DISABLED (base game behaviour)")
end

function ProductionInputFix.install()
    if ProductionPoint == nil or ProductionPoint.updateProduction == nil then
        Logging.warning("ProductionInputFix: ProductionPoint.updateProduction not found, fix not installed")
        return
    end

    ProductionPoint.updateProduction = Utils.overwrittenFunction(ProductionPoint.updateProduction, ProductionInputFix.updateProduction)
    if ProductionChainManager ~= nil and ProductionChainManager.update ~= nil then
        ProductionChainManager.update = Utils.overwrittenFunction(ProductionChainManager.update, ProductionInputFix.chainManagerUpdate)
    end

    if addConsoleCommand ~= nil then
        addConsoleCommand("pifInfo", "Lists production steps the fix limited and the output it kept from appearing", "consoleInfo", ProductionInputFix)
        addConsoleCommand("pifToggle", "Turns the production input fix on/off for A/B testing", "consoleToggle", ProductionInputFix)
    end

    Logging.info("ProductionInputFix: installed")
end

ProductionInputFix.install()
