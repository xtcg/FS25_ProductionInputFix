#!/bin/sh
# Packs the mod into ../FS25_ProductionInputFix.zip (runtime files only).
cd "$(dirname "$0")" || exit 1
rm -f ../FS25_ProductionInputFix.zip
zip -r -X ../FS25_ProductionInputFix.zip modDesc.xml LICENSE icon_ProductionInputFix.dds scripts -x '*.DS_Store'
