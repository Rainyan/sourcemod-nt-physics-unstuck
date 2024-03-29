# NT Physics Unstuck

SourceMod plugin for Neotokyo. Temporarily toggle physics prop collision if a player is stuck inside it.

This plugin should eliminate the situation where a player becomes completely stuck inside a physics object.

[unstuck_example.webm](https://user-images.githubusercontent.com/6595066/214193232-2d6abbc2-361f-46e9-a557-a07bac392187.webm)

## Build requirements

* SourceMod 1.10 or newer
  * **If using SourceMod older than 1.11**: you also need [the DHooks extension](https://forums.alliedmods.net/showpost.php?p=2588686). Download links are at the bottom of the opening post of the AlliedMods thread. Be sure to choose the correct one for your SM version! You don't need this if you're using SourceMod 1.11 or newer.
* [Neotokyo include](https://github.com/softashell/sourcemod-nt-include)

## Installation

* Place [the gamedata file](addons/sourcemod/gamedata/neotokyo/) to the `addons/sourcemod/gamedata/neotokyo` folder (create the "neotokyo" folder if it doesn't exist).
* Compile the plugin, and place the .smx binary file to `addons/sourcemod/plugins`
