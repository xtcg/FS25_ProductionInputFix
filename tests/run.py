"""Run tests/test_*.lua against tests/stubs.lua and the real base-game code.

The base functions (ProductionPoint:updateProduction, ProductionChainManager:update)
are read from the decompiled game source, not copied into this repo. Set FS25_SOURCE
to that folder (default: ../FS25 next to this repo).

    pip install lupa
    python tests/run.py
"""
import glob
import os
import re
import sys

import lupa

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)
SOURCE = os.environ.get("FS25_SOURCE", os.path.join(os.path.dirname(REPO), "FS25"))


def extract(path, start, end):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    m = re.search(re.escape(start) + r".*?(?=" + re.escape(end) + ")", text, re.S)
    if not m:
        sys.exit(f"cannot find {start!r} in {path}")
    return m.group(0)


def function_code(path, name):
    with open(path, encoding="utf-8") as f:
        source = f.read()
    match = re.search(r"function " + re.escape(name) + r"\(.*?(?=\nfunction |\Z)", source, re.S)
    if match is None:
        sys.exit(f"cannot find {name!r} in {path}")
    return match.group(0)


def base_code():
    pp = os.path.join(SOURCE, "dataS/scripts/objects/ProductionPoint.lua")
    cm = os.path.join(SOURCE, "dataS/scripts/misc/ProductionChainManager.lua")
    return (extract(pp, "function ProductionPoint:updateProduction()", "function ProductionPoint:updateTick")
            + "\n" + extract(cm, "function ProductionChainManager:update()", "function ProductionChainManager:hourChanged"))


def run(path, base):
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua.globals().REPO = REPO + "/"
    lua.globals().BASE_CODE = base
    with open(os.path.join(SOURCE, "hb_1.5b1/scripts/PlaceableMilkCollector.lua"), encoding="utf-8") as f:
        milk = f.read()
    lua.globals().HB_MILK_HOOK = milk[milk.index("function PlaceableMilkCollector.installProductionPointHooks()"):]
    with open(os.path.join(SOURCE, "hb_1.5b1/scripts/ExtendedProductionPointInputRefill.lua"), encoding="utf-8") as f:
        refill = f.read()
    lua.globals().HB_REFILL_HOOK = refill[refill.index("function ExtendedProductionPointInputRefill.install()"):refill.index("-- Keep the threshold descriptor")]
    pp = os.path.join(SOURCE, "dataS/scripts/objects/ProductionPoint.lua")
    hb = os.path.join(SOURCE, "hb_1.5b1/scripts/PlaceableExtendedProductionPoint.lua")
    lua.globals().HB_STATE_CODE = "\n".join([
        function_code(pp, "ProductionPoint:setProductionState"),
        function_code(pp, "ProductionPoint:setProductionStatus"),
        function_code(hb, "ExtendedProductionPoint:setProductionStatus"),
    ])
    with open(os.path.join(TESTS, "stubs.lua"), encoding="utf-8") as f:
        lua.execute(f.read())
    with open(path, encoding="utf-8") as f:
        lua.execute(f.read())
    results = lua.globals().RESULTS
    return [(results[i]["name"], results[i]["ok"], results[i]["msg"]) for i in range(1, len(results) + 1)]


def main():
    base = base_code()
    failed = 0
    for path in sorted(glob.glob(os.path.join(TESTS, "test_*.lua"))):
        for name, ok, msg in run(path, base):
            print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  -- " + str(msg)))
            failed += 0 if ok else 1
    print("failed: %d" % failed)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
