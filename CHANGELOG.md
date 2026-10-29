# Changelog

## 1.0.1 — 2026-10-29

- Open-sourced under the MIT License (replaces the earlier commercial license).

## 1.0.0 - 2026-10-29

- Added server-authoritative daily claims with per-player remote throttling.
- Added UTC and rolling 24-hour timing, grace periods, one-use streak freezes, and loop/cap reward cycles.
- Added configurable attribute, leaderstats, and custom callback rewards.
- Added versioned DataStore persistence with atomic claim validation, retry backoff, jitter, and Studio API-disabled memory fallback.
- Added public state, claimed signal, custom reward handler, reset, and adapter APIs.
- Added a code-built calendar popup with countdown, streak display, safe-area layout, and touch, keyboard, and gamepad controls.
- Added pure logic tests runnable with Lune and a documentation-only ProfileStore adapter example.
- Added Rojo live-service and Folder-root package projects, binary/XML model builds, demo place, and commercial license.

Claim-history persistence does not persist the default currency balance. External wallet delivery is not atomic with the claim record; see README.md before connecting a valuable economy.
