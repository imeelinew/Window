#!/bin/zsh
set -euo pipefail

# Build and install a Release copy of Window for daily use.
# Keep the current instance running until the new build is ready.

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
app_name="Window"
installed_app="/Applications/${app_name}.app"
derived_data="$repo_root/DerivedData"
built_app="$derived_data/Build/Products/Release/${app_name}.app"

cd "$repo_root"

print "Building Release"
xcodebuild \
    -project Window.xcodeproj \
    -scheme Window \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived_data" \
    build

[[ -d "$built_app" ]] || {
    print -u2 "Built app not found: $built_app"
    exit 70
}
codesign --verify --deep --strict "$built_app"

if pgrep -xq "$app_name"; then
    print "Quitting $app_name"
    osascript -e "tell application \"$app_name\" to quit" >/dev/null || true
    for _ in {1..20}; do
        pgrep -xq "$app_name" || break
        sleep 0.5
    done
    if pgrep -xq "$app_name"; then
        print -u2 "$app_name did not quit; force killing"
        killall "$app_name"
        sleep 1
    fi
fi

print "Installing to $installed_app"
rm -rf "$installed_app"
ditto "$built_app" "$installed_app"

print "Launching $app_name"
open "$installed_app"
