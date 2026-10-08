# FS25_ProductionInputFix

Production points in FS25 can make more output than their inputs allow. This mod stops that.

## The bug (base game, v1.23.1 `ProductionPoint:updateProduction`)

The production chain manager updates one production point per frame. When a point's turn comes, it runs one step that covers the time since its last update. `dt` is in real milliseconds and is capped at 30 s.

- **Input check:** `fillLevel < amount * cyclesPerMinute * (dt / 60000 * timeAdjust)`. This is the amount for one step at **real-time** speed.
- **Consumption and output:** `amount * cyclesPerMinute * dt * minuteFactorTimescaled * timeAdjust`. This is the same step at **game** speed, which is the real-time amount multiplied by the time scale.
- `Storage:setFillLevel` clamps the input at 0.

So an input holding between 1/timeScale of a step and one full step passes the check. The step then still produces its full output. How large a step is depends on `cyclesPerHour`, the time scale, and how many production points share the frames. On Hof Bergmann:

| Building | Recipe | Step at 120x, 4 s per point update |
|---|---|---|
| cream separator | 1 milk → 0.7 low-fat + 0.3 cream, 4000/h | 533 L |
| calf milk mixer (big and small) | 0.8 water + 0.2 powder → 1 calf milk, 2000/h | 267 L |
| milking carousel | 1 raw milk → 1 milk, 12000/h | 1600 L |

On the milking carousel the milk collector feeds about 133 L of raw milk per update. Each update then makes 1600 L of milk, 12 times the raw milk that went in.

## The fix

The mod hooks `ProductionChainManager.update`. Before the base game runs a point, it checks each active production. If a step needs more input than the point holds, or more output space than is free, the mod scales that production's `cyclesPerMinute` down for this step only. The step then uses at most what is there, and the value is restored right after.

The base loop and any wrappers a map adds (Hof Bergmann's input refill, milk collector, animal output) run unchanged. Steps that fit run exactly as in the base game. Production costs are untouched.

Behaviour that changes:

- Every recipe yields exactly its ratio.
- A small batch drains completely instead of leaving a remainder below one step.
- A nearly full output storage is filled to capacity instead of stalling with "no space".

Console commands:

- `pifInfo` lists each limited production and the output the unfixed game would have created from nothing.
- `pifToggle` switches the fix off and on, for A/B testing.

## Tests

The tests run the real base-game `updateProduction` and `ProductionChainManager:update`, read from the decompiled game source (`FS25_SOURCE`, default `../FS25`), with and without the fix.

    pip install lupa
    python tests/run.py

## Build

    ./build.sh   # -> ../FS25_ProductionInputFix.zip
