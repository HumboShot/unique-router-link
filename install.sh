#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

app="$HOME/Applications/Unique Router Link.app"
config="$HOME/.config/unique-router-link/rules.json"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mkdir -p build
swiftc -O -target arm64-apple-macos13 -o build/UniqueRouterLink main.swift

pkill -x UniqueRouterLink || true
mkdir -p "$app/Contents/MacOS"
cp build/UniqueRouterLink "$app/Contents/MacOS/UniqueRouterLink"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
"$lsregister" -f "$app"

if [[ ! -f "$config" ]]; then
  mkdir -p "${config:h}"
  cp rules.example.json "$config"
  echo "Created $config"
fi
echo "Installed $app"
