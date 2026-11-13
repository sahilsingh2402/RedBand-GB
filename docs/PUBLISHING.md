# Publishing RedBand GB (e.g. amazfitwatchfaces.com)

## Upload the ROM-free files

`RedBand_GB_4_6_0.bin` contains the whole Pokémon Red ROM (64 bank files). The ROM is Nintendo's
copyrighted game: it is fine on your own band from your own cartridge, but it must not be
uploaded for others to download. Upload these instead:

- `output/RedBand_GB_4_6_0_noROM.bin` (with the Poketch AOD)
- `output/RedBand_GB_4_6_0_noROM_noAOD.bin`

These carry the watchface without anything taken from the game: the Poketch clock with the
trainer, the AOD, BROWSE and the emulator shell. They contain no ROM and no engines, because the
engines' compiled blocks are translations of the game's own code. POWER shows "no game ROM in this
watchface".
Anyone who owns the game can build the full version from `RedBand_GB_4_6_0_Publish_noROM.zip`.
Put your own `pokemon_red.gb` in `rom/`, then run the build steps in `README_FIRST.md`
(`build_cores.py` makes the engines from your ROM).

## Description (suggested)

> **RedBand GB: a Game Boy in a watchface.** A complete Game Boy emulator written in Lua for the
> Xiaomi Smart Band 10.
> - **Display:** frames drawn by the band's GPU at full width.
> - **Speed:** a real-time clock keeps the game at full speed.
> - **Safety:** SAFE and FAST modes, crash-safe saves with a backup, and a Poketch-style clock
>   and AOD.
> - **Requirements:** bring your own ROM (see the project files). Band 10, firmware 3.1.x.

Tags: Pokemon, Game Boy, emulator, Poketch, retro, game.

## Pictures

- `docs/media/preview_main.png` (212x520, pill)
- `docs/media/preview_aod.png`
- `docs/media/preview_main_and_aod_x2.png`
- `docs/media/RedBand_GB_showcase.gif` (44 s tour)
- `docs/media/RedBand_GB_showcase_short.gif` (19 s)
- `docs/media/RedBand_GB_showcase_2x.gif` (424x1040)

The GIFs show real gameplay recorded with the emulator and the ROM. They are recordings, not the
ROM itself.

## Credits to show

- **Poketch clock and AOD glyphs:** from the "Poketch" Mi Band 6 watchface by **zantfaul**. Ask
  the author before publishing.
- **Pokémon, the trainer sprite, Game Boy:** © Nintendo / Creatures / GAME FREAK. Fan project,
  not affiliated, non-commercial.
- **Watchface container (AOD):** based on AIR-pixel/miband11-watchface-maker (MIT).
