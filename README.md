# DragonSword Radar

Minimap and world map markers for DragonSword: Awakening. Only needs UE4SS.

- **Dots:** unopened chests (orange = map treasure, green = minigame, white = other). The nearest one is ringed, with an arrow if it's above or below you.
- **Blue diamond:** side quest you can pick up from an NPC
- **Yellow bubble:** random NPC quest ("..." over their head) you haven't done
- **F8:** show/hide everything, **F9:** show/hide quest markers

Opened chests and finished quests are read from your save (read-only) and disappear on their own.

## Install

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) v4 into `DS\Binaries\Win64` (`dwmapi.dll` and `UE4SS.dll` next to the game exe).
2. Copy this repo's `Mods` folder into `DS\Binaries\Win64`.
3. If you have the old Treasure Radar mod, remove or disable it.

## Build

`native/build.sh` with MinGW-w64 g++ builds `dsradar.dll`.

## Notes

- Use a vanilla install for co-op.
- Some random quests (mostly in cities) have no map position in the game data, so they get no marker.
- Decompression uses [ooz](https://github.com/powzix/ooz), so this project is GPL-3.0.
