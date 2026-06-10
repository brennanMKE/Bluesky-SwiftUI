#!/usr/bin/env zsh
#
# screenshot.sh [--screen <name>]
#
# Captures the frontmost Bluesky (Beta build) window to screenshots/.
#
#   ./screenshot.sh                  # screenshots/screenshot_<timestamp>.png
#   ./screenshot.sh --screen home    # screenshots/home_<timestamp>.png
#
# Requires the Bluesky (Beta) scheme to be running.
# Run ./scripts/set-environment.sh Beta before building if needed.

BUNDLE_ID="co.sstools.Bluesky.beta"
APP_NAME="Bluesky"

SCREEN_NAME=""
if [[ "$1" == "--screen" && -n "$2" ]]; then
    SCREEN_NAME="$2"
fi

WINDOW_ID=$(windows | grep "$BUNDLE_ID" | head -1 | awk '{print $1}')

if [[ -z "$WINDOW_ID" ]]; then
    echo "error: $APP_NAME window not found — is the app running?" >&2
    echo "  Build: xcodebuild -scheme 'Bluesky (Beta)' (after ./scripts/set-environment.sh Beta)" >&2
    exit 1
fi

mkdir -p screenshots

TIMESTAMP=$(date +%Y%m%d%H%M%S)
if [[ -n "$SCREEN_NAME" ]]; then
    FILENAME="screenshots/${SCREEN_NAME}_${TIMESTAMP}.png"
else
    FILENAME="screenshots/screenshot_${TIMESTAMP}.png"
fi

/usr/sbin/screencapture -l "$WINDOW_ID" "$FILENAME" && echo "$FILENAME"
