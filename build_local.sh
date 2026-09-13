#!/usr/bin/env bash
set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────
R='\033[1;31m'  G='\033[1;32m'  Y='\033[1;33m'  B='\033[1;34m'
C='\033[1;36m'  M='\033[1;35m'  W='\033[1;37m'  D='\033[0m'
BG='\033[48;5;235m'  UL='\033[4m'  BL='\033[1m'
GREEN='\033[38;5;114m' RED='\033[38;5;203m' CYAN='\033[38;5;75m'
YELLOW='\033[38;5;220m' PINK='\033[38;5;213m' LGRAY='\033[38;5;250m'

# ── Helpers ─────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.build_config"

border() {
    local len=${#1} pad=2 total=$((len + pad * 2))
    local line=""
    for ((i=0; i<total; i++)); do line+="─"; done
    echo -e "${CYAN}┌${line}┐${D}"
    printf "${CYAN}│${D}%*s%s%*s${CYAN}│${D}\n" "$pad" "" "$1" "$pad" ""
    echo -e "${CYAN}└${line}┘${D}"
}

section() {
    echo ""
    echo -e "  ${PINK}▸${D} ${BL}${W}$1${D}"
    echo -e "  ${LGRAY}├──────────────────────────────────────${D}"
}

bullet() {
    echo -e "  ${PINK}│${D}  $1"
}

done_msg() {
    echo -e "  ${PINK}│${D}"
    echo -e "  ${PINK}╰─${D} ${GREEN}✓${D} $1"
}

warn_msg() {
    echo -e "  ${PINK}│${D}"
    echo -e "  ${PINK}╰─${D} ${YELLOW}⚠${D} $1"
}

fail_msg() {
    echo -e "  ${PINK}╰─${D} ${RED}✗${D} $1"
}

menu_header() {
    local title="$1" index="$2"
    echo ""
    echo -e "  ${PINK}╭──────────────────────────────────────╮${D}"
    printf "  ${PINK}│${D}  ${BL}${W}%-20s${D} ${LGRAY}[%s]${D}     ${PINK}│${D}\n" "$title" "$index"
    echo -e "  ${PINK}╰──────────────────────────────────────╯${D}"
}

# ── Box rows ────────────────────────────────────────────────────────
BOX_W=28
shorten() {
    local s="$1" w="${2:-$BOX_W}"
    if [ "${#s}" -gt "$w" ]; then
        echo "${s:0:$((w - 3))}..."
    else
        echo "$s"
    fi
}

menu_row() {
    local label="$1" value="$2" color="$3"
    value="$(shorten "$value")"
    printf "  ${CYAN}║${D}  ${LGRAY}%-8s${D} ${color}%s${D}%*s  ${CYAN}║${D}\n" \
        "$label" "$value" $((BOX_W - ${#value})) ""
}

# ── Defaults ────────────────────────────────────────────────────────
WORKSPACE="${WORKSPACE:-$HOME/twrp_workspace}"
INSTALL_DEPS="${INSTALL_DEPS:-1}"
SWAP_GB="${SWAP_GB:-12}"

MANIFEST_URL="${MANIFEST_URL:-}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-}"
DEVICE_NAME="${DEVICE_NAME:-}"
BUILD_TARGET="${BUILD_TARGET:-}"
LUNCH_TARGET="${LUNCH_TARGET:-}"
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

# ── Config persistence ──────────────────────────────────────────────
save_config() {
    cat > "$CONFIG_FILE" <<EOF
MANIFEST_URL="$MANIFEST_URL"
MANIFEST_BRANCH="$MANIFEST_BRANCH"
DEVICE_NAME="$DEVICE_NAME"
BUILD_TARGET="$BUILD_TARGET"
LUNCH_TARGET="$LUNCH_TARGET"
WORKSPACE="$WORKSPACE"
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
EOF
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# ── Telegram ────────────────────────────────────────────────────────
tg_notify() {
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="$1" \
            -d parse_mode=html \
            -d disable_web_page_preview=true || true
    fi
}

TG_EDIT_MSG_ID=""

tg_edit_or_send() {
    if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
        return 0
    fi
    local text="$1"
    if [ -n "$TG_EDIT_MSG_ID" ]; then
        local resp
        resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText" \
            -d chat_id="${TG_CHAT_ID}" \
            -d message_id="${TG_EDIT_MSG_ID}" \
            -d text="$text" \
            -d parse_mode=html)
        if echo "$resp" | python3 -c "import json,sys; exit(0 if json.load(sys.stdin).get('ok') else 1)" 2>/dev/null; then
            return 0
        fi
    fi
    local resp
    resp=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d text="$text" \
        -d parse_mode=html \
        -d disable_web_page_preview=true)
    TG_EDIT_MSG_ID=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('message_id',''))" 2>/dev/null || echo "")
}

tg_upload() {
    local file="$1" caption="${2:-}"
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] && [ -f "$file" ]; then
        local size
        size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
        local upload_file="$file"
        if [ "$size" -gt 52428800 ]; then
            bullet "File too large ($(numfmt --to=iec $size)). Compressing..."
            upload_file="${file}.lz4"
            lz4 -9 -q "$file" "$upload_file" 2>/dev/null || \
            gzip -9 -k -f -c "$file" > "${file}.gz" 2>/dev/null && upload_file="${file}.gz"
        fi
        if [ -f "$upload_file" ]; then
            curl -s -o /dev/null -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
                -F chat_id="${TG_CHAT_ID}" \
                -F "document=@${upload_file}" \
                -F caption="${caption}" && \
                rm -f "${file}.lz4" "${file}.gz" || \
                rm -f "${file}.lz4" "${file}.gz"
        fi
    fi
}

# ── Banner ──────────────────────────────────────────────────────────
show_banner() {
    echo ""
    echo -e "  ${CYAN}╔═══════════════════════════════════════╗${D}"
    echo -e "  ${CYAN}║${D}  ${BL}${M}  ╦═╗╔═╗╔╦╗╔╦╗╔═╗╦═╗${D}               ${CYAN}║${D}"
    echo -e "  ${CYAN}║${D}  ${BL}${M}  ╠╦╝║╣  ║║║║║║╣ ╠╦╝${D}               ${CYAN}║${D}"
    echo -e "  ${CYAN}║${D}  ${BL}${M}  ╩╚═╚═╝═╩╝╩╝╚═╝╩╚═${D}  ${LGRAY}v2.0${D}           ${CYAN}║${D}"
    echo -e "  ${CYAN}╚═══════════════════════════════════════╝${D}"
    echo ""
}

# ── Main Menu ───────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo -e "  ${CYAN}╔═══════════════════════════════════════════╗${D}"
    echo -e "  ${CYAN}║${D}  ${BL}${M}  ╦═╗╔═╗╔╦╗╔╦╗╔═╗╦═╗${D}                   ${CYAN}║${D}"
    echo -e "  ${CYAN}║${D}  ${BL}${M}  ╠╦╝║╣  ║║║║║║╣ ╠╦╝${D}                   ${CYAN}║${D}"
    echo -e "  ${CYAN}║${D}  ${BL}${M}  ╩╚═╚═╝═╩╝╩╝╚═╝╩╚═${D}  ${LGRAY}v2.0 Local${D}       ${CYAN}║${D}"
    echo -e "  ${CYAN}╠═══════════════════════════════════════════╣${D}"
    menu_row "Device:" "${DEVICE_NAME:-none}" "$M"
    menu_row "Branch:" "${MANIFEST_BRANCH:-none}" "$C"
    menu_row "Lunch:" "${LUNCH_TARGET:-none}" "$PINK"
    echo -e "  ${CYAN}╚═══════════════════════════════════════════╝${D}"
    echo ""
    echo -e "  ${LGRAY}Available Actions:${D}"
    echo -e "  ${LGRAY}─────────────────────────────────────────${D}"
    echo -e "  ${LGRAY}[1]${D}  Setup Workspace"
    echo -e "  ${LGRAY}[2]${D}  Sync Sources"
    echo -e "  ${LGRAY}[3]${D}  Build Recovery"
    echo -e "  ${LGRAY}[4]${D}  Flash to Device"
    echo -e "  ${LGRAY}[5]${D}  Clean"
    echo -e "  ${LGRAY}─────────────────────────────────────────${D}"
    echo -e "  ${LGRAY}[0]${D}  Exit"
    echo ""
}

# ── Operation: Setup ────────────────────────────────────────────────
do_setup() {
    echo ""
    echo -e "  ${CYAN}╔═══════════════════════════════════════╗${D}"
    echo -e "  ${CYAN}║${D}           ${BL}${W}SETUP WORKSPACE${D}              ${CYAN}║${D}"
    echo -e "  ${CYAN}╚═══════════════════════════════════════╝${D}"

    if [ -z "$MANIFEST_URL" ]; then
        menu_header "MANIFEST" "1/4"
        echo ""
        echo -e "    ${LGRAY}1)${D} ${G}TWRP${D}          ${LGRAY}minimal-manifest-twrp/aosp${D}"
        echo -e "    ${LGRAY}2)${D} ${C}SHRP${D}          ${LGRAY}rjfahad/manifest${D}"
        echo -e "    ${LGRAY}3)${D} ${M}PBRP${D}          ${LGRAY}PitchBlackRecoveryProject${D}"
        echo -e "    ${LGRAY}4)${D} ${Y}LineageOS${D}     ${LGRAY}minimal-manifest-twrp/lineageos${D}"
        echo -e "    ${LGRAY}5)${D} ${R}Custom URL${D}"
        echo ""
        read -rp $'    \e[1m► Select [1-5]: \e[0m' choice
        case "$choice" in
            1) MANIFEST_URL="https://github.com/minimal-manifest-twrp/platform_manifest_twrp_aosp" ;;
            2) MANIFEST_URL="https://github.com/rjfahad/manifest" ;;
            3) MANIFEST_URL="https://github.com/PitchBlackRecoveryProject/manifest_pb" ;;
            4) MANIFEST_URL="https://github.com/minimal-manifest-twrp/platform_manifest_twrp_lineageos" ;;
            5) read -rp $'    \e[1m► Enter URL: \e[0m' MANIFEST_URL ;;
            *) echo -e "    ${RED}Invalid choice${D}"; return 1 ;;
        esac
    fi

    if [ -z "$MANIFEST_BRANCH" ]; then
        menu_header "BRANCH" "2/4"
        echo ""
        echo -e "    ${LGRAY}1)${D} ${G}twrp-11${D}       ${LGRAY}2)${D} ${C}twrp-12.1${D}     ${LGRAY}3)${D} ${M}twrp-14.1${D}"
        echo -e "    ${LGRAY}4)${D} ${Y}shrp-12.1${D}     ${LGRAY}5)${D} ${G}v3_11.0${D}       ${LGRAY}6)${D} ${C}v3_10.0${D}"
        echo -e "    ${LGRAY}7)${D} ${M}android-12.1${D}  ${LGRAY}8)${D} ${Y}android-11.0${D}  ${LGRAY}9)${D} ${R}Custom${D}"
        echo ""
        read -rp $'    \e[1m► Select [1-9]: \e[0m' choice
        case "$choice" in
            1) MANIFEST_BRANCH="twrp-11" ;;
            2) MANIFEST_BRANCH="twrp-12.1" ;;
            3) MANIFEST_BRANCH="twrp-14.1" ;;
            4) MANIFEST_BRANCH="shrp-12.1" ;;
            5) MANIFEST_BRANCH="v3_11.0" ;;
            6) MANIFEST_BRANCH="v3_10.0" ;;
            7) MANIFEST_BRANCH="android-12.1" ;;
            8) MANIFEST_BRANCH="android-11.0" ;;
            9) read -rp $'    \e[1m► Enter branch: \e[0m' MANIFEST_BRANCH ;;
            *) echo -e "    ${RED}Invalid choice${D}"; return 1 ;;
        esac
    fi

    if [ -z "$DEVICE_NAME" ]; then
        menu_header "DEVICE" "3/4"
        echo ""
        read -rp $'    \e[1m► Device name \e[0m\e[38;5;250m[even]\e[0m: \e[0m' DEVICE_NAME
        DEVICE_NAME="${DEVICE_NAME:-even}"
    fi

    if [ -z "$LUNCH_TARGET" ]; then
        menu_header "LUNCH TARGET" "4/4"
        echo ""
        echo -e "    ${LGRAY}1)${D} ${G}twrp_${DEVICE_NAME}-eng${D}"
        echo -e "    ${LGRAY}2)${D} ${C}omni_${DEVICE_NAME}-eng${D}"
        echo -e "    ${LGRAY}3)${D} ${R}Custom target${D}"
        echo ""
        read -rp $'    \e[1m► Select [1-3]: \e[0m' choice
        case "$choice" in
            1) LUNCH_TARGET="twrp_${DEVICE_NAME}-eng" ;;
            2) LUNCH_TARGET="omni_${DEVICE_NAME}-eng" ;;
            3) read -rp $'    \e[1m► Enter target: \e[0m' LUNCH_TARGET ;;
            *) echo -e "    ${RED}Invalid choice${D}"; return 1 ;;
        esac
    fi

    if [ -z "$BUILD_TARGET" ]; then
        echo ""
        echo -e "    ${LGRAY}1)${D} ${G}recovery${D}"
        echo -e "    ${LGRAY}2)${D} ${C}boot${D}"
        echo ""
        read -rp $'    \e[1m► Build target [1-2]: \e[0m' choice
        case "$choice" in
            1) BUILD_TARGET="recovery" ;;
            2) BUILD_TARGET="boot" ;;
            *) echo -e "    ${RED}Invalid choice${D}"; return 1 ;;
        esac
    fi

    # ── Summary ──
    echo ""
    echo -e "  ${CYAN}╔═══════════════════════════════════════════╗${D}"
    echo -e "  ${CYAN}║${D}           ${BL}${W}BUILD CONFIGURATION${D}              ${CYAN}║${D}"
    echo -e "  ${CYAN}╠═══════════════════════════════════════════╣${D}"
    printf "  ${CYAN}║${D}  ${LGRAY}Manifest:${D}   ${G}%-28s${D}  ${CYAN}║${D}\n" "$(shorten "$MANIFEST_URL")"
    printf "  ${CYAN}║${D}  ${LGRAY}Branch:${D}     ${C}%-28s${D}  ${CYAN}║${D}\n" "$(shorten "$MANIFEST_BRANCH")"
    printf "  ${CYAN}║${D}  ${LGRAY}Device:${D}     ${M}%-28s${D}  ${CYAN}║${D}\n" "$(shorten "$DEVICE_NAME")"
    printf "  ${CYAN}║${D}  ${LGRAY}Target:${D}     ${Y}%-28s${D}  ${CYAN}║${D}\n" "$(shorten "${BUILD_TARGET}.img")"
    printf "  ${CYAN}║${D}  ${LGRAY}Lunch:${D}      ${PINK}%-28s${D}  ${CYAN}║${D}\n" "$(shorten "$LUNCH_TARGET")"
    printf "  ${CYAN}║${D}  ${LGRAY}Workspace:${D}  ${LGRAY}%-28s${D}  ${CYAN}║${D}\n" "$(shorten "$WORKSPACE")"
    echo -e "  ${CYAN}╚═══════════════════════════════════════════╝${D}"
    echo ""

    read -rp $'  \e[1mProceed with setup? \e[0m\e[38;5;250m[Y/n]\e[0m: \e[0m' CONFIRM
    if [[ "${CONFIRM,,}" == "n" || "${CONFIRM,,}" == "no" ]]; then
        echo -e "  ${RED}Aborted.${D}"
        return 1
    fi

    # ── Sudo Detection ──
    SUDO=""
    apt_ok=0
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            SUDO="sudo"
        fi
    fi
    [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ] && apt_ok=1

    tg_notify "$(printf '🚀 <b>Setup Started</b>\nManifest: %s\nBranch: %s\nDevice: %s' "$MANIFEST_URL" "$MANIFEST_BRANCH" "$DEVICE_NAME")"

    # ── Dependencies ──
    section "Installing dependencies"
    if [ "$INSTALL_DEPS" = "1" ] && [ "$apt_ok" = "1" ]; then
        APT_CMD="apt-get install -y"
        [ -n "$SUDO" ] && APT_CMD="$SUDO $APT_CMD"
        $SUDO apt update -qq 2>/dev/null
        $APT_CMD -qq zip unzip tar gzip bzip2 openjdk-8-jdk ccache rsync python3 2>/dev/null
        done_msg "Dependencies installed"
    elif [ "$INSTALL_DEPS" = "1" ]; then
        warn_msg "No root access — skipping apt"
        bullet "${LGRAY}Ensure installed: zip unzip openjdk-8-jdk ccache rsync python3${D}"
    fi

    if ! command -v java >/dev/null 2>&1; then
        fail_msg "Java 8 not found — install OpenJDK 8 before building"
    fi

    # ── Repo ──
    section "Setting up repo"
    if ! command -v repo >/dev/null 2>&1; then
        mkdir -p "$HOME/bin"
        curl -s https://storage.googleapis.com/git-repo-downloads/repo > "$HOME/bin/repo"
        chmod a+x "$HOME/bin/repo"
        export PATH="$HOME/bin:$PATH"
        done_msg "repo installed"
    else
        done_msg "repo already present"
    fi

    git config --global user.name "rjfahad"
    git config --global user.email "actions@github.com"

    # ── Workspace ──
    section "Preparing workspace"
    mkdir -p "$WORKSPACE"
    cd "$WORKSPACE"
    if [ ! -f .repo/manifest.xml ]; then
        bullet "Initializing repo..."
        repo init --depth=1 -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" 2>&1 | tail -1
    else
        bullet "Existing repo found"
    fi
    done_msg "Workspace ready at ${WORKSPACE}"

    # ── Swap ──
    if [ "$SWAP_GB" != "0" ] && [ "$(id -u)" -eq 0 ]; then
        CURRENT_SWAP_KB="$(awk '/^SwapTotal/ {print $2}' /proc/meminfo)"
        if [ "${CURRENT_SWAP_KB:-0}" -lt $((SWAP_GB * 1024 * 1024)) ] && [ ! -f /swapfile ]; then
            fallocate -l "${SWAP_GB}G" /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && echo "/swapfile none swap defaults 0 0" >> /etc/fstab
            done_msg "${SWAP_GB}G swap enabled"
        fi
    fi

    save_config
    tg_notify "$(printf '✅ <b>Setup Complete</b>\nDevice: %s\nBranch: %s' "$DEVICE_NAME" "$MANIFEST_BRANCH")"
    echo ""
    echo -e "  ${G}Setup done!${D}"
}

# ── Operation: Sync ─────────────────────────────────────────────────
do_sync() {
    if ! load_config 2>/dev/null; then
        fail_msg "No config found. Run Setup first."
        return 1
    fi

    echo ""
    echo -e "  ${CYAN}╔═══════════════════════════════════════╗${D}"
    echo -e "  ${CYAN}║${D}           ${BL}${W}SYNC SOURCES${D}                ${CYAN}║${D}"
    echo -e "  ${CYAN}╚═══════════════════════════════════════╝${D}"

    cd "$WORKSPACE"

    section "Syncing sources"
    bullet "Syncing with -j4 (avoiding rate limits)..."
    repo sync -c -j4 --force-sync --no-tags --no-clone-bundle 2>&1 | tail -1
    echo "Finalizing sync state..."
    repo sync -c -j4 2>&1 | tail -1 || true
    done_msg "Sources synced"

    section "Installing device tree"
    rm -rf "./device/realme/${DEVICE_NAME}"
    mkdir -p "./device/realme/${DEVICE_NAME}"
    rsync -a --exclude='.git' --exclude='.github' --exclude='build_local.sh' --exclude='.build_config' "$SCRIPT_DIR"/ "./device/realme/${DEVICE_NAME}/"
    done_msg "Device tree → device/realme/${DEVICE_NAME}"

    section "Syncing device dependencies"
    case "$MANIFEST_BRANCH" in
        twrp-11|twrp-12.1) BUILD_TREE="twrp" ;;
        *) BUILD_TREE="omni" ;;
    esac
    DEP_FILE="./device/realme/${DEVICE_NAME}/${BUILD_TREE}.dependencies"
    CONVERTER="./device/realme/${DEVICE_NAME}/scripts/convert.sh"
    if [ -f "$DEP_FILE" ]; then
        bullet "Found ${BUILD_TREE}.dependencies"
    fi
    if [ -f "$CONVERTER" ] && [ -f "$DEP_FILE" ]; then
        bullet "Running convert.sh on ${BUILD_TREE}.dependencies..."
        bash "$CONVERTER" "$DEP_FILE" 2>/dev/null || true
    fi
    repo sync -c -j4 2>&1 | tail -1
    done_msg "Dependencies synced"
}

# ── Operation: Build ────────────────────────────────────────────────
do_build() {
    if ! load_config 2>/dev/null; then
        fail_msg "No config found. Run Setup first."
        return 1
    fi

    echo ""
    echo -e "  ${CYAN}╔═══════════════════════════════════════════╗${D}"
    echo -e "  ${CYAN}║${D}           ${BL}${M}BUILDING RECOVERY${D}              ${CYAN}║${D}"
    echo -e "  ${CYAN}╚═══════════════════════════════════════════╝${D}"
    echo ""

    cd "$WORKSPACE"

    set +eu
    source build/envsetup.sh
    export ALLOW_MISSING_DEPENDENCIES=true
    export USE_CCACHE=1
    export CCACHE_COMPRESS=1
    export CCACHE_MAXSIZE=50G
    export CCACHE_DIR="$HOME/.ccache"
    export TZ=Asia/Jakarta
    export TW_THEME=portrait_hdpi
    export TARGET_SCREEN_WIDTH=720
    export TARGET_SCREEN_HEIGHT=1600

    tg_notify "$(printf '🔨 <b>Build Started</b>\nTime: %s\nDevice: %s\nTarget: %s\nLunch: %s\nBranch: %s\nManifest: %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$DEVICE_NAME" "$BUILD_TARGET" "$LUNCH_TARGET" "$MANIFEST_BRANCH" "$MANIFEST_URL")"

    local build_start=$SECONDS

    # ── Live progress to Telegram ──
    local build_log="$WORKSPACE/.build_live.log"
    : > "$build_log"
    TG_EDIT_MSG_ID=""

    _build_tg_sender() {
        while true; do
            sleep 5
            if [ ! -f "$build_log" ] || [ ! -s "$build_log" ]; then
                continue
            fi
            local lines
            lines=$(tail -20 "$build_log" 2>/dev/null | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' | head -c 3500)
            if [ -n "$lines" ]; then
                local msg
                msg=$(printf '📊 <b>Build Progress</b>\n<pre>%s</pre>' "$lines")
                tg_edit_or_send "$msg" >/dev/null 2>&1 || true
                : > "$build_log"
            fi
        done
    }
    _build_tg_sender &
    local tg_sender_pid=$!

    lunch "${LUNCH_TARGET}"
    if ! make "${BUILD_TARGET}image" -j"$(nproc --all)" 2>&1 | tee >( \
        grep -E '^\[[[:space:]]*[0-9]+%|^[[:space:]]+[0-9]+:[0-9]+ ' | while IFS= read -r line; do
            echo "$line" >> "$build_log"
        done \
    ); then
        kill "$tg_sender_pid" 2>/dev/null || true
        wait "$tg_sender_pid" 2>/dev/null || true
        set -eu
        fail_msg "Build FAILED"
        tg_notify "$(printf '❌ <b>Build Failed</b>\nTime: %s\nDevice: %s\nTarget: %s\nBranch: %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$DEVICE_NAME" "$BUILD_TARGET" "$MANIFEST_BRANCH")"
        return 1
    fi
    kill "$tg_sender_pid" 2>/dev/null || true
    wait "$tg_sender_pid" 2>/dev/null || true

    # ── Send final progress ──
    if [ -s "$build_log" ]; then
        local final_lines
        final_lines=$(cat "$build_log" | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' | head -c 3500)
        local final_msg
        final_msg=$(printf '📊 <b>Build Progress</b>\n<pre>%s</pre>' "$final_lines")
        tg_edit_or_send "$final_msg" >/dev/null 2>&1 || true
    fi
    rm -f "$build_log"
    set -eu

    # ── Package ──
    OUT_DIR="$WORKSPACE/out/target/product/${DEVICE_NAME}"
    if [ -f "$OUT_DIR/${BUILD_TARGET}.img" ]; then
        cd "$OUT_DIR"
        zip -j recovery.zip "${BUILD_TARGET}.img" >/dev/null 2>&1

        echo ""
        echo -e "  ${CYAN}╔═══════════════════════════════════════════╗${D}"
        echo -e "  ${CYAN}║${D}           ${BL}${G}BUILD COMPLETE${D}                ${CYAN}║${D}"
        echo -e "  ${CYAN}╠═══════════════════════════════════════════╣${D}"
        printf "  ${CYAN}║${D}  ${LGRAY}Image:${D}   ${G}%-30s${D}  ${CYAN}║${D}\n" "$(shorten "$OUT_DIR/${BUILD_TARGET}.img" 30)"
        printf "  ${CYAN}║${D}  ${LGRAY}Zip:${D}     ${G}%-30s${D}  ${CYAN}║${D}\n" "$(shorten "$OUT_DIR/recovery.zip" 30)"
        echo -e "  ${CYAN}╚═══════════════════════════════════════════╝${D}"

        local build_duration=$(( SECONDS - build_start ))
        local build_min=$(( build_duration / 60 ))
        local build_sec=$(( build_duration % 60 ))
        local build_caption
        build_caption=$(printf '✅ Build Complete\nTime: %s\nDuration: %sm %ss\nDevice: %s\nTarget: %s\nBranch: %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$build_min" "$build_sec" "$DEVICE_NAME" "$BUILD_TARGET" "$MANIFEST_BRANCH")

        bullet "Uploading to Telegram..."
        tg_upload "$OUT_DIR/recovery.zip" "$build_caption"
        done_msg "Uploaded to Telegram"
    else
        fail_msg "Build output not found at ${OUT_DIR}/${BUILD_TARGET}.img"
        return 1
    fi
}

# ── Operation: Flash to Device ──────────────────────────────────────
do_flash() {
    if ! load_config 2>/dev/null; then
        fail_msg "No config found. Run Setup first."
        return 1
    fi

    echo ""
    echo -e "  ${CYAN}╔═══════════════════════════════════════════╗${D}"
    echo -e "  ${CYAN}║${D}           ${BL}${Y}FLASH TO DEVICE${D}               ${CYAN}║${D}"
    echo -e "  ${CYAN}╚═══════════════════════════════════════════╝${D}"
    echo ""

    local img="$WORKSPACE/out/target/product/${DEVICE_NAME}/${BUILD_TARGET}.img"
    if [ ! -f "$img" ]; then
        fail_msg "Image not found: $img — build first."
        return 1
    fi

    echo -e "  ${LGRAY}Image:${D} ${G}$img${D}"
    echo -e "  ${LGRAY}Target partition:${D} ${Y}${BUILD_TARGET}${D}"
    echo ""
    echo -e "  ${LGRAY}1)${D} fastboot flash ${BUILD_TARGET}"
    echo -e "  ${LGRAY}2)${D} adb sideload-style push (device must be in recovery with adb)"
    echo ""
    read -rp $'  \e[1m► Select [1-2]: \e[0m' choice
    case "$choice" in
        1)
            if ! command -v fastboot >/dev/null 2>&1; then
                fail_msg "fastboot not found in PATH"
                return 1
            fi
            echo -e "  ${LGRAY}Waiting for fastboot device...${D}"
            fastboot devices
            read -rp $'  \e[1mProceed with flash? \e[0m\e[38;5;250m[y/N]\e[0m: \e[0m' CONFIRM
            if [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]]; then
                fastboot flash "$BUILD_TARGET" "$img"
                done_msg "Flashed ${BUILD_TARGET} partition"
            else
                echo -e "  ${RED}Aborted.${D}"
            fi
            ;;
        2)
            if ! command -v adb >/dev/null 2>&1; then
                fail_msg "adb not found in PATH"
                return 1
            fi
            adb devices
            adb push "$img" "/sdcard/${BUILD_TARGET}.img"
            done_msg "Pushed to /sdcard/${BUILD_TARGET}.img — flash manually from recovery"
            ;;
        *) echo -e "  ${RED}Invalid choice${D}"; return 1 ;;
    esac
}

# ── Operation: Clean ────────────────────────────────────────────────
do_clean() {
    if ! load_config 2>/dev/null; then
        fail_msg "No config found. Run Setup first."
        return 1
    fi

    echo ""
    echo -e "  ${CYAN}╔═══════════════════════════════════════════╗${D}"
    echo -e "  ${CYAN}║${D}              ${BL}${R}CLEAN${D}                       ${CYAN}║${D}"
    echo -e "  ${CYAN}╚═══════════════════════════════════════════╝${D}"
    echo ""
    echo -e "  ${LGRAY}1)${D} Clean device output (out/target/product/${DEVICE_NAME})"
    echo -e "  ${LGRAY}2)${D} Full clean (make clean)"
    echo -e "  ${LGRAY}3)${D} Reset config (re-run Setup next time)"
    echo ""
    read -rp $'  \e[1m► Select [1-3]: \e[0m' choice
    case "$choice" in
        1)
            rm -rf "$WORKSPACE/out/target/product/${DEVICE_NAME}"
            rm -f "$WORKSPACE/.build_live.log"
            done_msg "Device output cleaned"
            ;;
        2)
            cd "$WORKSPACE"
            set +eu
            source build/envsetup.sh >/dev/null 2>&1
            lunch "${LUNCH_TARGET}" >/dev/null 2>&1
            make clean
            set -eu
            done_msg "Full clean done"
            ;;
        3)
            rm -f "$CONFIG_FILE"
            MANIFEST_URL=""; MANIFEST_BRANCH=""; DEVICE_NAME=""
            BUILD_TARGET=""; LUNCH_TARGET=""
            done_msg "Config reset"
            ;;
        *) echo -e "  ${RED}Invalid choice${D}"; return 1 ;;
    esac
}

# ── Main loop ───────────────────────────────────────────────────────
load_config 2>/dev/null || true

while true; do
    show_menu
    read -rp $'  \e[1m❯ \e[0m' action
    case "$action" in
        1) do_setup ;;
        2) do_sync ;;
        3) do_build ;;
        4) do_flash ;;
        5) do_clean ;;
        0) echo -e "  ${LGRAY}Bye!${D}"; exit 0 ;;
        *) echo -e "  ${RED}Invalid choice${D}" ;;
    esac
    echo ""
    read -rp $'  Press Enter to continue...' _
done
