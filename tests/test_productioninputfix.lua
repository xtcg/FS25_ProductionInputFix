dofile(REPO .. "scripts/ProductionInputFix.lua")

local function cream(levels, caps, timeScale)
    return newPoint({
        name = "cream", timeScale = timeScale or 120,
        caps = caps or { MILK = 2000, LOWFATMILK = 2000, CREAM = 500 },
        levels = levels,
        productions = { { id = "cream", cph = 4000, inputs = { { "MILK", 1 } }, outputs = { { "LOWFATMILK", 0.7 }, { "CREAM", 0.3 } } } },
    })
end

local function calfMilk(water, powder)
    return newPoint({
        name = "calfMilkMixerBig", timeScale = 120,
        caps = { MILKPOWDER = 3600, WATER = 2000, CALFMILK = 5600 },
        levels = { WATER = water, MILKPOWDER = powder },
        productions = { { id = "calfmilk", cph = 2000, inputs = { { "WATER", 0.8 }, { "MILKPOWDER", 0.2 } }, outputs = { { "CALFMILK", 1 } } } },
    })
end

local function withFix(enabled, fn)
    local old = ProductionInputFix.enabled
    ProductionInputFix.enabled = enabled
    local ok, err = pcall(fn)
    ProductionInputFix.enabled = old
    if not ok then error(err, 0) end
end

test("installs on ProductionChainManager.update and logs", function()
    check(logContains("ProductionInputFix: installed"), "install log")
    check(COMMANDS.pifInfo ~= nil and COMMANDS.pifToggle ~= nil, "console commands")
end)

test("base game: 100 L milk at 120x, 4 s per point update -> 373 L low-fat + 160 L cream", function()
    withFix(false, function()
        local pp = cream({ MILK = 100 })
        runFrames(newManager({ pp }), 3, 4000)
        near(pp.storage:getFillLevel("MILK"), 0, 1e-9, "milk")
        near(pp.storage:getFillLevel("LOWFATMILK"), 0.7 * 4000 / 60 * 8, 1e-6, "low-fat")
        near(pp.storage:getFillLevel("CREAM"), 0.3 * 4000 / 60 * 8, 1e-6, "cream")
    end)
end)

test("fix: 100 L milk -> 70 L low-fat + 30 L cream", function()
    local pp = cream({ MILK = 100 })
    runFrames(newManager({ pp }), 3, 4000)
    near(pp.storage:getFillLevel("MILK"), 0, 1e-3, "milk")
    near(pp.storage:getFillLevel("LOWFATMILK"), 70, 1e-3, "low-fat")
    near(pp.storage:getFillLevel("CREAM"), 30, 1e-3, "cream")
    near(pp.activeProductions[1].cyclesPerMinute, 4000 / 60, 0, "cyclesPerMinute restored")
end)

test("fix: calf milk mixer, 100 L water + 1000 L powder -> 125 L calf milk", function()
    local pp = calfMilk(100, 1000)
    runFrames(newManager({ pp }), 5, 4000)
    near(pp.storage:getFillLevel("CALFMILK"), 125, 1e-3, "calf milk")
    near(pp.storage:getFillLevel("WATER"), 0, 1e-3, "water")
    near(pp.storage:getFillLevel("MILKPOWDER"), 975, 1e-3, "powder")
end)

test("base game: same calf milk mixer makes 533 L from 100 L water", function()
    withFix(false, function()
        local pp = calfMilk(100, 1000)
        runFrames(newManager({ pp }), 5, 4000)
        near(pp.storage:getFillLevel("CALFMILK"), 2000 / 60 * 8, 1e-6, "calf milk")
    end)
end)

test("fix leaves a step that fits exactly as the base game runs it", function()
    local a, b = cream({ MILK = 2000 }), cream({ MILK = 2000 })
    withFix(true, function() runFrames(newManager({ a }), 2, 4000) end)
    withFix(false, function() runFrames(newManager({ b }), 2, 4000) end)
    for _, t in ipairs({ "MILK", "LOWFATMILK", "CREAM" }) do
        check(a.storage:getFillLevel(t) == b.storage:getFillLevel(t), t .. " differs")
    end
    check(a.productionCostsToClaim == b.productionCostsToClaim, "costs differ")
end)

test("empty input still reports missing inputs and produces nothing", function()
    local pp = cream({ MILK = 0 })
    runFrames(newManager({ pp }), 2, 4000)
    check(pp.statuses.cream == ProductionPoint.PROD_STATUS.MISSING_INPUTS, "status " .. tostring(pp.statuses.cream))
    near(pp.storage:getFillLevel("LOWFATMILK"), 0, 0, "low-fat")
end)

test("output space: fills cream to capacity instead of stalling", function()
    local pp = cream({ MILK = 2000, CREAM = 490 })
    runFrames(newManager({ pp }), 1, 4000)
    near(pp.storage:getFillLevel("CREAM"), 500, 1e-3, "cream")
    near(pp.storage:getFillLevel("MILK"), 2000 - 10 / 0.3, 1e-3, "milk")
    near(pp.storage:getFillLevel("LOWFATMILK"), 10 / 0.3 * 0.7, 1e-3, "low-fat")
    runFrames(newManager({ pp }), 1, 4000)
    check(pp.statuses.cream == ProductionPoint.PROD_STATUS.NO_OUTPUT_SPACE, "full -> no output space")
end)

test("milking carousel: 133 L raw milk per update -> 1333 L milk over 10 updates (base: 16000)", function()
    local function carousel()
        return newPoint({
            name = "milkingCarusell", timeScale = 120,
            caps = { RAWMILK = 1200, MILK = 200000 },
            productions = { { id = "cows_processing", cph = 12000, inputs = { { "RAWMILK", 1 } }, outputs = { { "MILK", 1 } } } },
        })
    end
    local function feed(pp) return function() pp.storage:setFillLevel(pp.storage:getFillLevel("RAWMILK") + 2000 * 4 / 60, "RAWMILK") end end
    local fixed, base = carousel(), carousel()
    runFrames(newManager({ fixed }), 10, 4000, feed(fixed))
    withFix(false, function() runFrames(newManager({ base }), 10, 4000, feed(base)) end)
    near(fixed.storage:getFillLevel("MILK"), 20000 / 15, 1e-2, "fixed milk")
    near(base.storage:getFillLevel("MILK"), 16000, 1e-6, "base milk")
end)

test("1x time scale: a small batch drains completely with exact yield", function()
    local pp = cream({ MILK = 3 }, nil, 1)
    runFrames(newManager({ pp }), 5, 4000)
    near(pp.storage:getFillLevel("LOWFATMILK"), 2.1, 1e-3, "low-fat")
    near(pp.storage:getFillLevel("MILK"), 0, 1e-3, "milk")
end)

test("two productions sharing one input never use more than it holds", function()
    local pp = newPoint({
        name = "cheese", timeScale = 120, shared = true,
        caps = { MILK = 1200, CHEESE = 5000, BUTTER = 5000 },
        levels = { MILK = 50 },
        productions = {
            { id = "a", cph = 3000, inputs = { { "MILK", 1 } }, outputs = { { "CHEESE", 1 } } },
            { id = "b", cph = 3000, inputs = { { "MILK", 1 } }, outputs = { { "BUTTER", 1 } } },
        },
    })
    runFrames(newManager({ pp }), 4, 4000)
    near(pp.storage:getFillLevel("CHEESE") + pp.storage:getFillLevel("BUTTER"), 50, 1e-3, "outputs")
end)

test("sell-directly outputs are not limited by storage space", function()
    local pp = newPoint({
        name = "sell", timeScale = 2, caps = { MILK = 2000 }, levels = { MILK = 2000 },
        productions = { { id = "s", cph = 60, inputs = { { "MILK", 1 } }, outputs = { { "MILK_BOTTLED", 1, true } } } },
    })
    runFrames(newManager({ pp }), 1, 30000) -- base clamps dt at 30 s
    near(pp.soldFillTypesToPayOut.MILK_BOTTLED, 1, 1e-9, "sold")
end)

test("unowned points are left to the base game", function()
    local pp = cream({ MILK = 100 })
    pp.isOwned = false
    check(ProductionInputFix.limitSteps(pp) == nil, "changed an unowned point")
end)

test("cyclesPerMinute is restored when the base update errors", function()
    local pp = cream({ MILK = 100 })
    pp.owningPlaceable.productionStatusChanged = function() error("boom") end
    local manager = newManager({ pp })
    pp.lastUpdatedTime = g_time
    g_time = g_time + 4000
    local ok, err = pcall(manager.update, manager)
    check(not ok and tostring(err):find("boom"), "error not raised")
    near(pp.activeProductions[1].cyclesPerMinute, 4000 / 60, 0, "cyclesPerMinute")
end)

test("pifInfo reports the output kept from appearing; pifToggle flips", function()
    ProductionInputFix.stats = {}
    local pp = cream({ MILK = 100 })
    runFrames(newManager({ pp }), 1, 4000)
    local info = COMMANDS.pifInfo()
    check(info:find("cream / cream: 1 steps limited", 1, true), info)
    check(info:find("LOWFATMILK 303", 1, true) and info:find("CREAM 130", 1, true), info)
    check(COMMANDS.pifToggle():find("DISABLED"), "toggle off")
    check(COMMANDS.pifToggle():find("enabled"), "toggle on")
end)
