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
-- Fix: right before the chain manager runs a production point, every active
-- production whose step does not fit gets its cyclesPerMinute scaled down so
-- the step uses at most what the inputs hold and the outputs can take. The
-- value is restored right after. The base loop and every wrapper a map or mod
-- put around updateProduction run unchanged.

ProductionInputFix = {}
ProductionInputFix.MOD_NAME = g_currentModName
ProductionInputFix.enabled = true
ProductionInputFix.MARGIN = 0.999999 -- keep the scaled step just below the stock so float rounding never trips the base check
ProductionInputFix.MIN_FACTOR = 1e-6 -- below this the base check reports missing inputs / no space by itself
ProductionInputFix.stats = {}

--- Scales the step of each active production of one point.
-- @return list of {production, cyclesPerMinute} to restore, or nil if nothing changed
function ProductionInputFix.limitSteps(productionPoint)
    if not ProductionInputFix.enabled or productionPoint == nil or not productionPoint.isOwned then
        return nil
    end

    local productions = productionPoint.activeProductions
    if productionPoint.lastUpdatedTime == nil or productions == nil or #productions == 0 then
        return nil
    end

    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    local timeAdjust = environment ~= nil and environment.timeAdjustment or 1
    local dt = math.clamp(g_time - productionPoint.lastUpdatedTime, 0, 30000)
    local minuteFactorDt = dt * (productionPoint.minuteFactorTimescaled or 0) * timeAdjust
    local realMinutes = dt / 60000 * timeAdjust
    local divisor = productionPoint.sharedThroughputCapacity and #productions or 1

    local levels = {}
    local freeSpace = {}
    local changed = nil

    -- Hof Bergmann's animal-input points round animal fill levels up for the HUD unless this flag is set
    local wasUpdating = productionPoint.updatingProduction
    productionPoint.updatingProduction = true

    for _, production in ipairs(productions) do
        local cyclesPerMinute = production.cyclesPerMinute or 0
        local stepCycles = cyclesPerMinute * minuteFactorDt
        local factor = 1
        local inputLimited = false
        local baseWouldPass = true

        for _, input in ipairs(production.inputs) do
            if levels[input.type] == nil then
                levels[input.type] = productionPoint:getFillLevel(input.type) or 0
            end

            local level = levels[input.type]
            local consumed = input.amount * stepCycles / divisor
            -- the base check asks for this much; when it is stricter than the real use, honour it
            local checked = input.amount * cyclesPerMinute * realMinutes
            local need = math.max(consumed, checked)

            if level < checked then
                baseWouldPass = false
            end

            if need > 0 and level < need then
                factor = math.min(factor, level / need)
                inputLimited = true
            end
        end

        for _, output in ipairs(production.outputs) do
            if not output.sellDirectly then
                if freeSpace[output.type] == nil then
                    freeSpace[output.type] = productionPoint.storage:getFreeCapacity(output.type) or 0
                end

                -- the base checks the undivided amount against free space
                local need = output.amount * stepCycles
                if need > 0 and freeSpace[output.type] < need then
                    factor = math.min(factor, freeSpace[output.type] / need)
                    baseWouldPass = false
                end
            end
        end

        if factor < 1 then
            if factor >= ProductionInputFix.MIN_FACTOR then
                factor = factor * ProductionInputFix.MARGIN
                changed = changed or {}
                table.insert(changed, {production, cyclesPerMinute})
                production.cyclesPerMinute = cyclesPerMinute * factor

                if inputLimited and baseWouldPass then
                    ProductionInputFix.recordWithheld(productionPoint, production, stepCycles / divisor * (1 - factor))
                end
            else
                factor = 0 -- leave the step as is; the base check stops it
            end
        end

        if factor > 0 then
            local cycles = stepCycles * factor / divisor
            for _, input in ipairs(production.inputs) do
                levels[input.type] = levels[input.type] - input.amount * cycles
            end
            for _, output in ipairs(production.outputs) do
                if not output.sellDirectly then
                    freeSpace[output.type] = freeSpace[output.type] - output.amount * cycles
                end
            end
        end
    end

    productionPoint.updatingProduction = wasUpdating

    return changed
end

function ProductionInputFix.restore(changed)
    if changed ~= nil then
        for _, entry in ipairs(changed) do
            entry[1].cyclesPerMinute = entry[2]
        end
    end
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

function ProductionInputFix.chainManagerUpdate(manager, superFunc, ...)
    local points = manager.productionPoints
    local count = points ~= nil and #points or 0

    if count == 0 then
        return superFunc(manager, ...)
    end

    -- the same point the base update is about to run
    local index = manager.currentUpdateIndex or 1
    if index > count then
        index = 1
    end

    local changed = ProductionInputFix.limitSteps(points[index])
    if changed == nil then
        return superFunc(manager, ...)
    end

    local ok, err = pcall(superFunc, manager, ...)
    ProductionInputFix.restore(changed)

    if not ok then
        error(err, 0)
    end
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
    if ProductionChainManager == nil or ProductionChainManager.update == nil then
        Logging.warning("ProductionInputFix: ProductionChainManager.update not found, fix not installed")
        return
    end

    ProductionChainManager.update = Utils.overwrittenFunction(ProductionChainManager.update, ProductionInputFix.chainManagerUpdate)

    if addConsoleCommand ~= nil then
        addConsoleCommand("pifInfo", "Lists production steps the fix limited and the output it kept from appearing", "consoleInfo", ProductionInputFix)
        addConsoleCommand("pifToggle", "Turns the production input fix on/off for A/B testing", "consoleToggle", ProductionInputFix)
    end

    Logging.info("ProductionInputFix: installed")
end

ProductionInputFix.install()
