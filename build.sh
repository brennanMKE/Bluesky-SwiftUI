#!/usr/bin/env zsh

set -eo pipefail

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Directories — PROJECT_NAME is derived from the folder name, never hardcoded
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
WORKSPACE="$(find "$PROJECT_DIR" -maxdepth 1 -name "*.xcworkspace" | head -1)"
BUILD_DIR="$PROJECT_DIR/.build"

log_info()    { echo "${BLUE}ℹ ${1}${NC}" }
log_success() { echo "${GREEN}✓ ${1}${NC}" }
log_warning() { echo "${YELLOW}⚠ ${1}${NC}" }
log_error()   { echo "${RED}✗ ${1}${NC}" }

clean() {
    log_info "Cleaning build artifacts..."

    if [[ -d "$BUILD_DIR" ]]; then
        rm -rf "$BUILD_DIR"
        log_success "Cleaned .build directory"
    fi

    log_success "Clean complete"
}

build() {
    log_info "Building $PROJECT_NAME..."

    xcodebuild -workspace "$WORKSPACE" \
        -scheme "$PROJECT_NAME" \
        -configuration Debug \
        -derivedDataPath "$BUILD_DIR/xcode" \
        -allowProvisioningUpdates \
        build 2>&1 | tee "$PROJECT_DIR/build.log" || {
        log_error "Build failed. See build.log for details."
        return 1
    }

    log_success "$PROJECT_NAME built successfully"
}

version() {
    log_info "Version Information:"
    echo "  Xcode: $(xcodebuild -version)"
    echo "  Project: $PROJECT_DIR"
    echo "  Swift: $(swift --version 2>/dev/null | head -1)"
}

show_help() {
    print "${BLUE}${PROJECT_NAME} Build Script${NC}\n"
    echo "${GREEN}Usage:${NC}"
    echo "  ./build.sh [action]"
    echo ""
    echo "${GREEN}Actions:${NC}"
    echo "  clean      - Remove all build artifacts"
    echo "  build      - Build debug configuration"
    echo "  version    - Show version information"
    echo "  help       - Show this help message"
    echo ""
    echo "${GREEN}Examples:${NC}"
    echo "  ./build.sh clean"
    echo "  ./build.sh build"
    echo ""
    echo "${YELLOW}Note:${NC} Run from project root directory"
}

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        return 0
    fi

    for action in "$@"; do
        case "$action" in
            clean)   clean ;;
            build)   build ;;
            version) version ;;
            help)    show_help ;;
            *)
                log_error "Unknown action: $action"
                show_help
                exit 1
                ;;
        esac
    done
}

main "$@"
