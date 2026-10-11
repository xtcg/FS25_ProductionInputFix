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

test("installs on ProductionPoint.updateProduction and logs", function()
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

-- Use HB's real collector wrapper: it captures the base method at specialization
-- load, and transfers milk inside updateProduction, after the chain-manager call.
local function hbCarousel(refill, initial, capturedBeforeFix)
    ExtendedProductionPoint = setmetatable({}, { __index = ProductionPoint })
    ExtendedProductionPoint.superClass = function() return ProductionPoint end
    if capturedBeforeFix then
        ExtendedProductionPoint.updateProduction = BASE_UPDATE_PRODUCTION
    end
    ExtendedProductionPoint.load = function() return true end
    ExtendedProductionPoint.loadFromXMLFile = function() end
    ExtendedProductionPoint.updateAutoFillInputs = function(self)
        near(self.activeProductions[1].cyclesPerMinute, 200, 0, "throughput during refill")
    end
    ExtendedProductionPointInputRefill = { updateFullOutputSpawns = function() end }
    load(HB_REFILL_HOOK)()
    ExtendedProductionPointInputRefill.install()
    PlaceableMilkCollector = {}
    load(HB_MILK_HOOK)()
    PlaceableMilkCollector.installProductionPointHooks()
    local pp = newPoint({
        name = "HB carousel", timeScale = 120,
        caps = { RAWMILK = 5000, MILK = 200000 }, levels = { RAWMILK = initial or 0 },
        productions = { { id = "milk", cph = 12000, inputs = { { "RAWMILK", 1 } }, outputs = { { "MILK", 1 } } } },
    })
    setmetatable(pp, { __index = ExtendedProductionPoint })
    pp.owningPlaceable.transferMilkToProductionPoint = function()
        -- The collector must see the configured throughput, not a limited one.
        near(pp.activeProductions[1].cyclesPerMinute, 200, 0, "throughput before transfer")
        pp.storage:setFillLevel(pp.storage:getFillLevel("RAWMILK") + refill, "RAWMILK")
    end
    -- HB also wraps each animal-input instance for unrounded production reads.
    local old = pp.updateProduction
    pp.updateProduction = function(self, ...)
        self.updatingProduction = true
        local result = old(self, ...)
        self.updatingProduction = false
        return result
    end
    return pp
end

test("HB wrapper order: empty raw milk refilled inside update yields 133 L, not 1600 L", function()
    local pp = hbCarousel(2000 * 4 / 60)
    runFrames(newManager({ pp }), 10, 4000)
    near(pp.storage:getFillLevel("MILK"), 20000 / 15, 0.01, "milk from transferred stock")
    near(pp.storage:getFillLevel("RAWMILK"), 0, 0.001, "raw milk remaining")
    near(pp.activeProductions[1].cyclesPerMinute, 200, 0, "throughput restored")
    check(pp.updatingProduction == false, "instance wrapper completes")
end)

test("HB wrapper reproduces 1600 L from 133 L with the fix disabled", function()
    withFix(false, function()
        local pp = hbCarousel(2000 * 4 / 60)
        runFrames(newManager({ pp }), 1, 4000)
        near(pp.storage:getFillLevel("MILK"), 1600, 1e-6, "base milk")
    end)
end)

test("HB refill is counted before limiting a previously small input", function()
    local pp = hbCarousel(2000, 10)
    runFrames(newManager({ pp }), 1, 4000)
    near(pp.storage:getFillLevel("MILK"), 1600, 1e-6, "full step after refill")
    near(pp.storage:getFillLevel("RAWMILK"), 410, 1e-6, "remaining input")
end)


test("HB wrappers loaded before fix: refill boundary still limits the captured base loop", function()
    local pp = hbCarousel(2000 * 4 / 60, 0, true)
    local inheritedRefill = pp.updateAutoFillInputs
    runFrames(newManager({ pp }), 10, 4000)
    near(pp.storage:getFillLevel("MILK"), 20000 / 15, 0.01, "captured-base milk")
    near(pp.activeProductions[1].cyclesPerMinute, 200, 0, "throughput restored")
    check(rawget(pp, "updateAutoFillInputs") == nil and pp.updateAutoFillInputs == inheritedRefill, "temporary method removed")
end)

test("HB captured-base error restores throughput and instance refill method", function()
    local pp = hbCarousel(2000 * 4 / 60, 0, true)
    pp.owningPlaceable.productionStatusChanged = function() error("HB boom") end
    local refill = pp.updateAutoFillInputs
    pp.lastUpdatedTime = g_time
    g_time = g_time + 4000
    local manager = newManager({ pp })
    local ok, err = pcall(manager.update, manager)
    check(not ok and tostring(err):find("HB boom", 1, true), "base error propagated")
    near(pp.activeProductions[1].cyclesPerMinute, 200, 0, "throughput restored after error")
    check(rawget(pp, "updateAutoFillInputs") == nil and pp.updateAutoFillInputs == refill, "refill method restored after error")
end)


local function chainPoint(shared, reverse)
    local recipes = {
        { id = "a_to_b", cph = 60, inputs = {{"A", 1}}, outputs = {{"B", 1}} },
        { id = "b_to_c", cph = 600, inputs = {{"B", 1}}, outputs = {{"C", 1}} },
    }
    if reverse then recipes[1], recipes[2] = recipes[2], recipes[1] end
    return newPoint({ timeScale = 120, shared = shared, caps = { A=5000, B=5000, C=5000 },
        levels = { A=100 }, productions = recipes })
end

test("sequential A -> B -> C uses 8 A to produce at most 8 C", function()
    local pp = chainPoint(false)
    local recipes = pp.activeProductions
    runFrames(newManager({pp}), 1, 4000)
    near(pp.storage:getFillLevel("A"), 92, 1e-9, "A")
    near(pp.storage:getFillLevel("B") + pp.storage:getFillLevel("C"), 8, 1e-6, "conserved B+C")
    near(pp.storage:getFillLevel("C"), 8, 0.001, "C")
    check(pp.activeProductions == recipes and pp.pifStepView == nil, "recipe view removed")
end)

test("shared sequential chain conserves inputs across multiple updates", function()
    local pp = chainPoint(true)
    runFrames(newManager({pp}), 4, 4000)
    near(pp.storage:getFillLevel("A") + pp.storage:getFillLevel("B") + pp.storage:getFillLevel("C"), 100, 1e-6, "A+B+C")
end)

test("reverse recipe order does not consume future output", function()
    local pp = chainPoint(false, true)
    runFrames(newManager({pp}), 1, 4000)
    near(pp.storage:getFillLevel("C"), 0, 0, "no B yet")
    near(pp.storage:getFillLevel("B"), 8, 1e-6, "B after later recipe")
    runFrames(newManager({pp}), 1, 4000)
    near(pp.storage:getFillLevel("A") + pp.storage:getFillLevel("B") + pp.storage:getFillLevel("C"), 100, 1e-6, "conserved stock")
end)


test("lazy rate preserves an inherited rate and the recipe's original metatable", function()
    local pp = cream({ MILK = 100 })
    local recipe = pp.activeProductions[1]
    local inherited = { cyclesPerMinute = recipe.cyclesPerMinute, marker = "original" }
    recipe.cyclesPerMinute = nil
    local mt = { __index = inherited }
    setmetatable(recipe, mt)
    local active = pp.activeProductions
    pp.owningPlaceable.productionStatusChanged = function()
        check(pp.activeProductions == active and recipe.marker == "original", "callback sees original array and inherited fields")
    end
    runFrames(newManager({pp}), 1, 4000)
    near(pp.storage:getFillLevel("LOWFATMILK"), 70, 0.001, "limited output")
    check(getmetatable(recipe) == mt and rawget(recipe, "cyclesPerMinute") == nil,
        "metatable and absent raw rate restored")
    near(recipe.cyclesPerMinute, 4000/60, 0, "inherited rate restored")
end)
