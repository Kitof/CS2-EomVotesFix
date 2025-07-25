# Display Workshop Map Names and Thumbnails During End-of-Match Vote

![Alt text](img/VoteWithThumbnails.png?raw=true "Vote With Thumbnails")

I tried to understand why **CS2 does not display workshop map thumbnails during end-of-match voting** when the dedicated server is launched with a map collection (`+host_workshop_collection`). 

[I already did the job for CSGO](https://github.com/Kitof/csgo_workshop_vote_fix/), but things are more complex for CS2.

> The fix is complex, requires multiple steps, and affects clients more than the server. Unfortunately, you have to modify gameinfo.gi, which is forbidden by VAC (even though this modification is completely harmless), **so clients will no longer be able to connect to VAC servers and your server will have to be launched with -insecure.**
Note that a rollback is provided via an uninstall.bat file and takes just 1 click to return to the initial state and allow you to play on VAC servers again.

To make deployment **easy during a LAN event I organized**, the script is written in **PowerShell**, and *it will generate the script to share with the players* (inside `build/client/*`. Just copy all files and launch install.bat or uninstall.bat to rollback).

Any PC under windows do the job. You don't need to generate the script from the server, but the `gamemodes_server.txt` file to copy to the server is also generated. (Only needed if you want to mix Classic and Workshop maps, or if you have an another plugin who use it)

---

## Requirements to generate the client script

- Install the [CS2 Workshop Tools](https://developer.valvesoftware.com/wiki/Counter-Strike_2_Workshop_Tools/Installing_and_Launching_Tools)

- Know your **Workshop Collection ID**  
  Example: `https://steamcommunity.com/sharedfiles/filedetails/?id=*3082703162*`

- Decide whether you want to **also include official maps** in the vote list

🛠️ All other dependencies are downloaded automatically - many thanks for their works :

- [Source 2 Viewer](https://valveresourceformat.github.io)
- [VPKEdit](https://github.com/craftablescience/VPKEdit)
- [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD)

---

## What the script actually does

- Retrieves the list of maps from the collection
- Tries to identify the internal map name (not exposed in CS2’s API — usually requires downloading the map; caching avoids doing this every time)
- Deduces:
  - the internal map name (e.g. `de_bank`)
  - a friendly name (e.g. `Bank`)
- Retrieves the thumbnail via the Steam API
- Compile the `.png` into `.vtex_c` (CS2-compatible format for thumbnails)
- Edits `gamemodes.txt` to include the map list
- Updates all language files to include the friendly names
- Packages everything into a `.vpk`
- Generates `gamemodes_server.txt` for the server (needed only if you want to mix classic and workshop maps)
- Generates the **client script** to:
  - copy the `.vpk` into `game/csgo`
  - modify `gameinfo.gi` to include the `.vpk`

---

## License

MIT — do whatever you want, credit appreciated.
