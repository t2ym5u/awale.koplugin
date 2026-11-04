# Changelog

All notable changes to this project will be documented in this file.

## [1.0.4] - 2026-11-04

### Changed
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.0.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- Awalé / Oware with abapa rules: laps skip the origin pit, captures of 2s
  and 3s going backwards, grand slam allowed but capturing nothing,
  compulsory feeding, win at 25.
- Endless-cycle endings: a third repetition of a position, or 100 moves
  without a capture, ends the game with each player keeping their own seeds.
- AI opponent at three levels (negamax, alpha-beta, iterative deepening on a
  time budget), or two players on one device; play as South or North.
- Undo, auto-save with undo history, large seed counts with dots.
