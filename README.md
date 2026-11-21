# Foxfire

Host a Minecraft Java Edition server on your Mac. Use its dashboard to switch between server profiles, manage worlds and backups, install compatible mods, and see live server performance.

## Build on macOS

Use an Apple Silicon Mac with macOS 14 or later, the Xcode Command Line Tools, and a JDK with `javac` and `jar` that supports Java 17 as a compilation target.

Run `./build.sh` from the project directory. Unzip `build/Foxfire.zip` and open `Foxfire.app`.

## Server data

Foxfire stores local server data under `~/Library/Application Support/Lantern Minecraft/`. In the app, select a server and choose **World → Open server folder** to find its files.
