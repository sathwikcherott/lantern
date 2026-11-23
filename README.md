# Lantern

Host a Minecraft Java Edition server on your Mac. Use its dashboard to switch between server profiles, manage worlds and backups, install compatible mods, and see live server performance.

## Install on another Mac

Lantern runs on Apple Silicon with macOS 14 or later.

1. Sign in to GitHub, then download `Lantern.zip` from [the latest release](https://github.com/sathwikcherott/lantern/releases/latest).
2. Unzip the download, move `Lantern.app` to Applications, and open it.
3. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway**. The release uses an ad hoc signature. [Apple’s first-launch instructions](https://support.apple.com/en-us/102445)

Lantern can download the Java runtime when you start a server. For world management and sleep features, install Apple's Command Line Tools using `xcode-select --install` if `/usr/bin/python3` is unavailable.

## Build on macOS

Use an Apple Silicon Mac with macOS 14 or later, the Xcode Command Line Tools, and a JDK with `javac` and `jar` that supports Java 17 as a compilation target.

Run `./build.sh` from the project directory. Unzip `build/Lantern.zip` and open `Lantern.app`.

## Server data

Lantern stores local server data under `~/Library/Application Support/Lantern Minecraft/`. In the app, select a server and choose **World → Open server folder** to find its files.
