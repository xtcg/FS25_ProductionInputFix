dofile(REPO .. "scripts/ProductionInputFix.lua")

-- Real engine state/status functions and HB's autoOff callback, not a callback
-- stand-in that merely updates a status table.
ExtendedProductionPoint = {
    AUTO_OFF_PROD_STATUS = {
        [ProductionPoint.PROD_STATUS.MISSING_INPUTS] = true,
        [ProductionPoint.PROD_STATUS.NO_OUTPUT_SPACE] = true,
    },
    superClass = function() return ProductionPoint end,
}
ProductionPointProductionStateEvent = { sendEvent = function() end }
load(HB_STATE_CODE)()

local function iterationHelpers(iterator)
    table.hasElement = function(list, item)
        for _, value in iterator(list) do if value == item then return true end end
        return false
    end
    table.removeElement = function(list, item)
        for key, value in iterator(list) do
            if value == item then table.remove(list, key); return true end
        end
        return false
    end
end

local function point(level, full)
    local pp = newPoint({ timeScale = 120, caps = { A=5000, B=5000 }, levels = { A=level, B=full and 5000 or 0 },
        productions = { { id="a", cph=60, inputs={{"A",1}}, outputs={{"B",1}} } } })
    local recipe = pp.activeProductions[1]
    recipe.extendedFeaturesAutoOff, recipe.index = true, 1
    pp.productionsIdToObj = { a = recipe }
    pp.extendedFeaturesAlwaysActive = false
    pp.setProductionStatus = ExtendedProductionPoint.setProductionStatus
    pp.owningPlaceable.outputsChanged = function() end
    return pp, recipe
end

for name, iterator in pairs({ pairs=pairs, ipairs=ipairs }) do
    for _, enabled in ipairs({false, true}) do
        for _, full in ipairs({false, true}) do
            test(string.format("real HB autoOff (%s, fix=%s, %s) retains removal", name, tostring(enabled), full and "full output" or "missing input"), function()
                iterationHelpers(iterator)
                local previous = ProductionInputFix.enabled
                ProductionInputFix.enabled = enabled
                local pp, recipe = point(full and 100 or 0, full)
                local original, metatable = pp.activeProductions, getmetatable(recipe)
                local observations = 0
                pp.owningPlaceable.outputsChanged = function(_, _, state)
                    observations = observations + 1
                    check(state == false, "HB disabled production")
                    check(pp.activeProductions == original and #original == 0, "callback sees original array with removal applied")
                end
                local ok, err = pcall(runFrames, newManager({pp}), 1, 4000)
                ProductionInputFix.enabled = previous
                check(ok, tostring(err))
                check(pp.activeProductions == original and #original == 0, "autoOff remains after update")
                check(observations == 1, "real setProductionState notified outputsChanged")
                check(recipe.status == (full and ProductionPoint.PROD_STATUS.NO_OUTPUT_SPACE or ProductionPoint.PROD_STATUS.MISSING_INPUTS), "HB retains reason status")
                check(getmetatable(recipe) == metatable and recipe.cyclesPerMinute == 1, "recipe rate and metatable restored")
            end)
        end
    end

    test("real HB autoOff (" .. name .. ") preserves preceding recipe and callback activation", function()
        iterationHelpers(iterator)
        local pp, missing = point(0)
        local first = { id="first", index=2, cyclesPerMinute=1, costsPerActiveMinute=0,
            inputs={}, outputs={{type="B", amount=1}}, status=0 }
        local replacement = { id="next", index=3, cyclesPerMinute=100, costsPerActiveMinute=0,
            inputs={{type="B", amount=1}}, outputs={{type="A", amount=1}}, status=0 }
        table.insert(pp.activeProductions, 1, first)
        pp.productionsIdToObj.first, pp.productionsIdToObj.next = first, replacement
        local original = pp.activeProductions
        pp.owningPlaceable.outputsChanged = function(_, _, active)
            check(pp.activeProductions == original, "state callback keeps the real array")
            if not active then pp:setProductionState("next", true) end
        end
        runFrames(newManager({pp}), 1, 4000)
        check(#original == 2 and original[1] == first and original[2] == replacement, "removed recipe stays removed and activation persists")
        check(not table.hasElement(original, missing), "missing recipe not resurrected")
        near(pp.storage:getFillLevel("B"), 8, 1e-6, "preceding recipe output")
        runFrames(newManager({pp}), 1, 4000)
        check(pp.storage:getFillLevel("A") <= 16 and pp.storage:getFillLevel("A") > 15.99, "new recipe is limited on the next update")
    end)

    test("real HB autoOff (" .. name .. ") removal survives a callback error", function()
        iterationHelpers(iterator)
        local pp, recipe = point(0)
        local original, metatable = pp.activeProductions, getmetatable(recipe)
        pp.owningPlaceable.outputsChanged = function() error("autoOff callback failure") end
        local ok, err = pcall(runFrames, newManager({pp}), 1, 4000)
        check(not ok and tostring(err):find("autoOff callback failure", 1, true), "callback error propagated")
        check(pp.activeProductions == original and #original == 0, "error does not undo completed removal")
        check(getmetatable(recipe) == metatable and recipe.cyclesPerMinute == 1 and pp.pifStepView == nil, "temporary rate hook cleaned up")
    end)
end

-- Removing the first recipe shifts middle out of this cached-count loop. Last
-- produces B, and the callback-activated recipe then runs in the final slot.
local function sameLoopPoint(shared)
    local pp, missing = point(0)
    pp.sharedThroughputCapacity = shared
    pp.storage.caps.C = 5000
    local middle = { id="middle", index=2, cyclesPerMinute=1, costsPerActiveMinute=0,
        inputs={}, outputs={{type="B", amount=1}}, status=0 }
    local last = { id="last", index=3, cyclesPerMinute=1, costsPerActiveMinute=0,
        inputs={}, outputs={{type="B", amount=1}}, status=0 }
    local nextRecipe = { id="next", index=4, cyclesPerMinute=10, costsPerActiveMinute=0,
        inputs={{type="B", amount=1}}, outputs={{type="C", amount=1}}, status=0 }
    local mt = { __index = { marker="registered" } }
    setmetatable(nextRecipe, mt)
    pp.activeProductions = {missing, middle, last}
    pp.productions = {missing, middle, last, nextRecipe}
    pp.productionsIdToObj.middle, pp.productionsIdToObj.last, pp.productionsIdToObj.next = middle, last, nextRecipe
    local original = pp.activeProductions
    pp.owningPlaceable.outputsChanged = function(_, _, active)
        check(pp.activeProductions == original, "activation keeps original active array")
        check(#pp.pifStepView.entries == 4, "each recipe has exactly one hook despite overlapping registries")
        if not active then pp:setProductionState("next", true) end
    end
    return pp, nextRecipe, mt, original
end

for name, iterator in pairs({pairs=pairs, ipairs=ipairs}) do
    for _, shared in ipairs({false, true}) do
        test(string.format("same-loop callback activation (%s, shared=%s) is limited and restored", name, tostring(shared)), function()
            iterationHelpers(iterator)
            local pp, nextRecipe, mt, original = sameLoopPoint(shared)
            runFrames(newManager({pp}), 1, 4000)
            local produced = shared and 8/3 or 8
            near(pp.storage:getFillLevel("C"), produced, 0.001, "new recipe uses actual B, not a full 80 L step")
            near(pp.storage:getFillLevel("B") + pp.storage:getFillLevel("C"), produced, 1e-6, "B+C conserved")
            check(pp.activeProductions == original and #original == 3 and original[3] == nextRecipe,
                "same-loop activation persists")
            check(getmetatable(nextRecipe) == mt and rawget(nextRecipe, "cyclesPerMinute") == 10,
                "newly active recipe's metatable and raw rate restored")
            for _, recipe in ipairs(pp.productions) do
                check(rawget(recipe, "cyclesPerMinute") == (recipe == nextRecipe and 10 or 1),
                    "all registered hooks restored, including skipped and removed recipes")
            end
            check(pp.pifStepView == nil, "temporary hook state removed")
        end)
    end

    test("same-loop activated recipe (" .. name .. ") hooks restore on output error", function()
        iterationHelpers(iterator)
        local pp, nextRecipe, mt, original = sameLoopPoint(false)
        local setFillLevel = pp.storage.setFillLevel
        pp.storage.setFillLevel = function(self, value, fillType)
            setFillLevel(self, value, fillType)
            if fillType == "C" then error("activated output failure") end
        end
        local ok, err = pcall(runFrames, newManager({pp}), 1, 4000)
        check(not ok and tostring(err):find("activated output failure", 1, true), "output error propagated")
        near(pp.storage:getFillLevel("C"), 8, 0.001, "failing output was limited too")
        check(pp.activeProductions == original and original[3] == nextRecipe, "activation survives error cleanup")
        check(getmetatable(nextRecipe) == mt and rawget(nextRecipe, "cyclesPerMinute") == 10,
            "newly active recipe restored after error")
        for _, recipe in ipairs(pp.productions) do
            check(rawget(recipe, "cyclesPerMinute") == (recipe == nextRecipe and 10 or 1), "all hooks restored after error")
        end
        check(pp.pifStepView == nil, "error removes temporary state")
    end)
end
