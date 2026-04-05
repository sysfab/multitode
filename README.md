### WARNING: THIS MOD IS WIP AND HAS BUGS

# Multitode
Multiplayer co-op mod for Infinitode 2  

## How to install
1. Click green `<> Code` button
2. Select `Download ZIP`
3. Prepare separate game installation (copy game folder to another location)
4. Unzip this mod into this game
5. Add as external Steam game.

## For developers
If you want to change Java bridge code (see `./multitode/`), you must recompile it with JDK 17+ (but use `--release 16` - it's the game's target)  
Example commands:  
```sh
#...
mod_root="$script_dir/multitode"
src_dir="$mod_root/src/main/java"
build_dir="$mod_root/build/classes"
dist_dir="$mod_root/dist"
jar_path="$dist_dir/bridge.jar"
game_jar="$script_dir/infinitode-2.jar"

javac --release 16 -cp "$game_jar" -d "$build_dir" "${java_files[@]}"
jar --create --file "$jar_path" -C "$build_dir" .
```  

All other things are managed with Lua API (see `./scripts/`)  
