# Legacy compatibility fixtures

Version: 1.0
Updated: 2026-10-26

These frozen JSON cases were generated from the independent Hammerspoon baseline
at window-management commit b715c96f0a9b0148976fa61e938c76e15bbbc352, using its
geometry-oracle.lua, focus-oracle.lua and accordion-oracle.lua drivers and the
original Lua geometry/focus/accordion implementations. They contain synthetic
frames/IDs only, not saved user layouts or app contents.

The source is https://github.com/theeseuus/window-management/tree/b715c96f0a9b0148976fa61e938c76e15bbbc352 .
The original project is MIT licensed. These are regression evidence, not a runtime
or build dependency on that checkout. Preserve the fixtures when changing the
Swift implementation; do not regenerate expectations from the Swift code under test.
