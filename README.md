# DragonSword Radar Quests

Add-on for the [Treasure Radar Overlay](https://www.nexusmods.com/dragonswordawakening/mods/63) mod (DragonSword: Awakening) by AInine. It adds quest markers to the minimap and world map, and fixes the mod not loading on UE4SS v4.

- **Blue diamond:** side quest you can get from an NPC
- **Yellow speech bubble:** random NPC quest ("..." over their head) you haven't done yet
- **F9:** show/hide quest markers (F8 still toggles everything)

## Install

1. Install UE4SS v4 and Treasure Radar v2.0.0 as described on the Nexus page. Make sure `dwmapi.dll` from UE4SS is in `DS\Binaries\Win64`.
2. Copy this repo's `Mods` folder into `DS\Binaries\Win64` and overwrite.

## Notes

- If quests you already finished still show a bubble (for example after playing with the mod off), run `Sync completed quests.cmd` in the mod folder while the game is running with your save loaded. It only reads your save.
- About 35 random quests (mostly city NPCs and the Welldone bounties) have no map position in the game data, so they get no marker.
- Updating Treasure Radar overwrites these files. Copy them in again afterwards.
