#!/usr/bin/env zsh
#
# screenshots-all.sh
#
# Iterates through the app's key screens, pausing between each so you can
# navigate to the right screen before the capture fires.
#
# Usage:
#   ./screenshots-all.sh
#
# The script assumes the Beta build of Bluesky is already running.
# Build it first:
#   ./scripts/set-environment.sh Beta
#   xcodebuild -scheme "Bluesky (Beta)" -configuration Debug build

SCREENS=(
    home
    thread
    profile
    search
    notifications
    messages
    composer
    settings
    moderation
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCREENSHOT="${SCRIPT_DIR}/screenshot.sh"

echo "screenshots-all.sh: capturing ${#SCREENS[@]} screens"
echo "Navigate to each screen when prompted, then press Return."
echo ""

CAPTURED=()

for SCREEN in "${SCREENS[@]}"; do
    echo -n "→ Navigate to '$SCREEN', then press Return to capture... "
    read -r
    FILE=$("$SCREENSHOT" --screen "$SCREEN")
    if [[ $? -eq 0 ]]; then
        echo "  ✓ $FILE"
        CAPTURED+=("$FILE")
    else
        echo "  ✗ capture failed — skipping $SCREEN"
    fi
done

echo ""
echo "Done. ${#CAPTURED[@]}/${#SCREENS[@]} screenshots saved to screenshots/:"
for F in "${CAPTURED[@]}"; do
    echo "  $F"
done
