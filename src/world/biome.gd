extends RefCounted
## Terrain categories shared by the generator, renderer and UI.

const OCEAN := 0
const PLAINS := 1
const FOREST := 2
const HILLS := 3
const MOUNTAINS := 4
const DESERT := 5
const STEPPE := 6
const TUNDRA := 7
const COUNT := 8

const NAMES := ["Sea", "Plains", "Forest", "Hills", "Mountains", "Desert", "Steppe", "Tundra"]

const COLORS := [
	Color8(40, 70, 98), Color8(170, 172, 108), Color8(92, 122, 74), Color8(156, 142, 98),
	Color8(132, 118, 102), Color8(214, 188, 132), Color8(186, 172, 116), Color8(170, 176, 166),
]
const LOWLAND := Color8(128, 150, 90)
const SNOW := Color8(236, 236, 232)
const RIVER := Color8(62, 104, 140)
const OCEAN_DEEP := Color8(24, 44, 68)
const OCEAN_SHALLOW := Color8(74, 116, 132)

## Relative cost of extending control across a province (used for border shapes).
const MOVE_COST := [9.0, 1.0, 1.3, 1.6, 3.2, 1.7, 1.15, 1.5]
## Settlement potential, used only to pick the size of the town marker for now.
const FERTILITY := [0.0, 1.0, 0.7, 0.6, 0.2, 0.25, 0.5, 0.25]
