#!/usr/bin/env bash
# Builds the Google Play listing images from the app icon and the screens captured by StoreScreenshots:
#   ./gradlew connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.storeShots=true \
#     -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true
#   adb pull /sdcard/Android/data/com.rohankanjani.lull/files/store <folder>
#   android/scripts/play-listing-images.sh <folder>
# Matches the App Store set in screenshots/final: same headlines, same blue. Needs ImageMagick.
set -euo pipefail

shots="${1:?Pass the folder of captured screens}"
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$root/fastlane/metadata/android/en-US/images"
font="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
blue="#2143D6"
mkdir -p "$out/phoneScreenshots"

magick "$root/Lull/Assets.xcassets/AppIcon.appiconset/icon.png" -resize 512x512 "$out/icon.png"

# Play wants 1024x500: the icon beside the name and tagline, on the icon's own night colour.
magick -size 1024x500 xc:"#05050A" \
  \( "$root/Lull/Assets.xcassets/AppIcon.appiconset/icon.png" -resize 360x360 \) -gravity west -geometry +70+0 -composite \
  -fill white -font "$font" -pointsize 120 -gravity northwest -annotate +470+130 "Lull" \
  -fill "#9A9AA6" -pointsize 34 -annotate +474+290 "Schedule your BedJet 3" -annotate +474+336 "through the night." \
  "$out/featureGraphic.png"

frame() { # screen, headline, subline, output
  local tmp; tmp="$(mktemp -d)"
  magick "$1" -resize 820x "$tmp/screen.png"
  local size; size="$(magick identify -format '%wx%h' "$tmp/screen.png")"
  magick -size "$size" xc:none -fill white -draw "roundrectangle 0,0 819,%[fx:h-1] 64,64" "$tmp/mask.png" 2>/dev/null ||
    magick -size "$size" xc:none -fill white -draw "roundrectangle 0,0 819,$(( ${size#*x} - 1 )) 64,64" "$tmp/mask.png"
  magick "$tmp/screen.png" "$tmp/mask.png" -alpha off -compose CopyOpacity -composite "$tmp/rounded.png"
  magick "$tmp/rounded.png" \( +clone -background black -shadow 70x28+0+16 \) +swap -background none -layers merge +repage "$tmp/shadowed.png"
  magick -size 1080x1920 xc:"$blue" \
    -fill white -font "$font" -gravity north -pointsize 150 -annotate +0+110 "$2" \
    -pointsize 62 -annotate +0+290 "$3" \
    "$tmp/shadowed.png" -gravity north -geometry +0+480 -composite \
    -crop 1080x1920+0+0 +repage "$4"
  rm -rf "$tmp"
}

frame "$shots/02-schedule.png" "PLAN" "YOUR WHOLE NIGHT" "$out/phoneScreenshots/1.png"
frame "$shots/05-running.png" "SLEEP" "WHILE IT RUNS ITSELF" "$out/phoneScreenshots/2.png"
frame "$shots/03-editor.png" "BUILD" "SCHEDULES THAT FIT YOU" "$out/phoneScreenshots/3.png"
frame "$shots/04-phase.png" "TUNE" "EVERY PHASE" "$out/phoneScreenshots/4.png"
frame "$shots/01-remote.png" "CONTROL" "HEAT, COOL AND FAN" "$out/phoneScreenshots/5.png"
echo "Wrote $out"
