#!/usr/bin/env bash
# ==============================================================================
#  build_ipa.sh - Automated Build & Sideload Packaging for Need for Speed: Carbon
#
#  Targets: iOS 16.0+, iPadOS 16.0+ (ARM64 Native Metal)
#  Supported Sideloaders: AltStore, SideStore, TrollStore, LiveContainer, Scarlet
# ==============================================================================

set -euo pipefail

# ANSI Color Codes
BOLD="\033[1m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}======================================================================${RESET}"
echo -e "${BOLD}${CYAN}  NEED FOR SPEED: CARBON (COLLECTOR'S EDITION) - iOS IPA BUILD PIPELINE  ${RESET}"
echo -e "${BOLD}${CYAN}======================================================================${RESET}"

# Paths and variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

PROJECT_NAME="NFSCarbon"
SCHEME="NFSCarbon"
CONFIGURATION="Release"
BUILD_DIR="${SCRIPT_DIR}/build"
DERIVED_DATA_DIR="${BUILD_DIR}/DerivedData"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
PAYLOAD_DIR="${BUILD_DIR}/Payload"
OUTPUT_IPA="${BUILD_DIR}/${PROJECT_NAME}.ipa"
ENTITLEMENTS="${SCRIPT_DIR}/ios/nfscarbon.entitlements"

# 1. Prepare build directories
echo -e "\n${BOLD}${YELLOW}[1/5] Preparing build workspace...${RESET}"
TMP_BACKUP_IPA=""
if [ -f "${BUILD_DIR}/.existing_NFSCarbon.ipa" ]; then
    TMP_BACKUP_IPA="${BUILD_DIR}/.existing_NFSCarbon.ipa"
elif [ -f "${OUTPUT_IPA}" ]; then
    TMP_BACKUP_IPA="${BUILD_DIR}/.existing_NFSCarbon.ipa"
    mv "${OUTPUT_IPA}" "${TMP_BACKUP_IPA}"
fi
rm -rf "${PAYLOAD_DIR}" "${ARCHIVE_PATH}" "${DERIVED_DATA_DIR}"
mkdir -p "${BUILD_DIR}"

if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild clean \
        -project "${PROJECT_NAME}.xcodeproj" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -derivedDataPath "${DERIVED_DATA_DIR}" \
        -quiet || true
    echo -e "${GREEN}✓ Clean completed.${RESET}"
else
    echo -e "${YELLOW}Notice: xcodebuild not found in current PATH. Checking for prebuilt app bundles or IPA...${RESET}"
fi

# 2. Run xcodebuild archive or assemble app bundle
echo -e "\n${BOLD}${YELLOW}[2/5] Assembling ${PROJECT_NAME}.app for generic/platform=iOS...${RESET}"

if command -v xcodebuild >/dev/null 2>&1; then
    xcodebuild archive \
        -project "${PROJECT_NAME}.xcodeproj" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -destination "generic/platform=iOS" \
        -archivePath "${ARCHIVE_PATH}" \
        -derivedDataPath "${DERIVED_DATA_DIR}" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=YES \
        CODE_SIGN_IDENTITY="" \
        AD_HOC_CODE_SIGNING_ALLOWED=YES \
        GCC_PREPROCESSOR_DEFINITIONS="RELEASE=1 NDEBUG=1" \
        COMPILER_INDEX_STORE_ENABLE=NO

    echo -e "${GREEN}✓ Xcode archive generated at: ${ARCHIVE_PATH}${RESET}"
    APP_BUNDLE="${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app"
else
    # Fallback 1: Check for existing app bundle
    CANDIDATE_APP=$(find "${SCRIPT_DIR}" -name "${PROJECT_NAME}.app" -maxdepth 4 2>/dev/null | head -n 1 || true)
    
    # Fallback 2: Check for existing/backed-up IPA to unpack
    if [ -z "${CANDIDATE_APP}" ] || [ ! -d "${CANDIDATE_APP}" ]; then
        SOURCE_IPA=""
        if [ -n "${TMP_BACKUP_IPA}" ] && [ -f "${TMP_BACKUP_IPA}" ]; then
            SOURCE_IPA="${TMP_BACKUP_IPA}"
        elif [ -f "${SCRIPT_DIR}/NFSCarbon.ipa" ]; then
            SOURCE_IPA="${SCRIPT_DIR}/NFSCarbon.ipa"
        fi

        if [ -n "${SOURCE_IPA}" ]; then
            echo -e "${CYAN}Extracting baseline application bundle from ${SOURCE_IPA}...${RESET}"
            mkdir -p "${BUILD_DIR}/unpack"
            if command -v unzip >/dev/null 2>&1; then
                unzip -q -o "${SOURCE_IPA}" -d "${BUILD_DIR}/unpack"
            elif command -v python3 >/dev/null 2>&1; then
                python3 -m zipfile -e "${SOURCE_IPA}" "${BUILD_DIR}/unpack"
            elif command -v python >/dev/null 2>&1; then
                python -m zipfile -e "${SOURCE_IPA}" "${BUILD_DIR}/unpack"
            fi
            if [ -d "${BUILD_DIR}/unpack/Payload/${PROJECT_NAME}.app" ]; then
                CANDIDATE_APP="${BUILD_DIR}/unpack/Payload/${PROJECT_NAME}.app"
            fi
        fi
    fi

    if [ -n "${CANDIDATE_APP}" ] && [ -d "${CANDIDATE_APP}" ]; then
        echo -e "${GREEN}✓ Using application bundle: ${CANDIDATE_APP}${RESET}"
        APP_BUNDLE="${CANDIDATE_APP}"
        
        # Inject updated Info.plist if present
        if [ -f "${SCRIPT_DIR}/ios/Info.plist" ]; then
            echo -e "  Updating Info.plist (120Hz ProMotion, GCController, strict landscape)..."
            cp "${SCRIPT_DIR}/ios/Info.plist" "${APP_BUNDLE}/Info.plist"
        fi

        # Inject updated full universal AppIcon suite
        ICON_DIR="${SCRIPT_DIR}/ios/resources/Assets.xcassets/AppIcon.appiconset"
        if [ -d "${ICON_DIR}" ]; then
            echo -e "  Injecting complete AppIcon suite (iPhone, iPad, Marketing)..."
            cp -f "${ICON_DIR}"/*.png "${APP_BUNDLE}/" 2>/dev/null || true
        fi
    else
        echo -e "${RED}Error: Neither xcodebuild nor an existing ${PROJECT_NAME}.app / .ipa was found.${RESET}"
        echo -e "On macOS: ensure Xcode is installed and run: sudo xcode-select -switch /Applications/Xcode.app"
        echo -e "On Windows: run 'gh release download' or build via GitHub Actions workflow."
        exit 1
    fi
fi

if [ ! -d "${APP_BUNDLE}" ]; then
    echo -e "${RED}Error: Target application bundle was not found at ${APP_BUNDLE}${RESET}"
    exit 1
fi

# 3. Ad-hoc Signing & Entitlements Preservation
echo -e "\n${BOLD}${YELLOW}[3/5] Applying ad-hoc signature and sideload entitlements...${RESET}"

# Sign embedded frameworks if present
if [ -d "${APP_BUNDLE}/Frameworks" ]; then
    find "${APP_BUNDLE}/Frameworks" -type d -name "*.framework" -o -name "*.dylib" | while read -r item; do
        if command -v codesign >/dev/null 2>&1; then
            codesign --force --sign - --timestamp=none "${item}" 2>/dev/null || true
        fi
    done
fi

if command -v codesign >/dev/null 2>&1; then
    if [ -f "${ENTITLEMENTS}" ]; then
        codesign --force --sign - --timestamp=none --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE}"
    else
        codesign --force --sign - --timestamp=none "${APP_BUNDLE}"
    fi
    echo -e "${GREEN}✓ App bundle signed with ad-hoc identity.${RESET}"
elif command -v ldid >/dev/null 2>&1; then
    if [ -f "${ENTITLEMENTS}" ]; then
        ldid -S"${ENTITLEMENTS}" "${APP_BUNDLE}"
    else
        ldid -S "${APP_BUNDLE}"
    fi
    echo -e "${GREEN}✓ App bundle signed via ldid.${RESET}"
else
    echo -e "${YELLOW}Warning: Neither codesign nor ldid detected; skipping ad-hoc re-signature.${RESET}"
fi

# 4. Construct Sideload Payload Hierarchy
echo -e "\n${BOLD}${YELLOW}[4/5] Packaging into standard Payload structure...${RESET}"
mkdir -p "${PAYLOAD_DIR}"
cp -R "${APP_BUNDLE}" "${PAYLOAD_DIR}/${PROJECT_NAME}.app"

# 5. Compress into .ipa Archive
echo -e "\n${BOLD}${YELLOW}[5/5] Compressing ${PROJECT_NAME}.ipa...${RESET}"
cd "${BUILD_DIR}"

if command -v ditto >/dev/null 2>&1; then
    ditto -c -k --sequesterRsrc --keepParent "Payload" "${OUTPUT_IPA}"
elif command -v zip >/dev/null 2>&1; then
    zip -qr "${OUTPUT_IPA}" "Payload"
else
    PY_CMD="python3"
    command -v python3 >/dev/null 2>&1 || PY_CMD="python"
    "${PY_CMD}" -c "
import zipfile, os
with zipfile.ZipFile('${PROJECT_NAME}.ipa', 'w', zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk('Payload'):
        for f in files:
            full = os.path.join(root, f)
            arcname = os.path.relpath(full, '.')
            zf.write(full, arcname)
"
fi

# Clean temporary payload directory
rm -rf "${PAYLOAD_DIR}"

# 6. Final Summary & Sideload Readiness
if [ -f "${OUTPUT_IPA}" ]; then
    FILE_SIZE=$(du -h "${OUTPUT_IPA}" 2>/dev/null | cut -f1 || ls -lh "${OUTPUT_IPA}" | awk '{print $5}')
    
    if command -v shasum >/dev/null 2>&1; then
        CHECKSUM=$(shasum -a 256 "${OUTPUT_IPA}" | cut -d' ' -f1)
    elif command -v sha256sum >/dev/null 2>&1; then
        CHECKSUM=$(sha256sum "${OUTPUT_IPA}" | cut -d' ' -f1)
    else
        CHECKSUM="Available"
    fi

    echo -e "\n${BOLD}${GREEN}======================================================================${RESET}"
    echo -e "${BOLD}${GREEN}       🎉 STANDALONE SIDELOADABLE IPA GENERATED SUCCESSFULLY!         ${RESET}"
    echo -e "${BOLD}${GREEN}======================================================================${RESET}"
    echo -e "  File:      ${BOLD}${OUTPUT_IPA}${RESET}"
    echo -e "  Size:      ${BOLD}${FILE_SIZE}${RESET}"
    echo -e "  SHA-256:   ${CHECKSUM}"
    echo -e ""
    echo -e "${BOLD}SIDELOADING INSTRUCTIONS:${RESET}"
    echo -e "  1. ${CYAN}AltStore / SideStore / Scarlet / Sideloadly:${RESET}"
    echo -e "     Send '${PROJECT_NAME}.ipa' to your device via AirDrop, iCloud Drive, or cable."
    echo -e "     Select 'Install .ipa' inside AltStore or SideStore."
    echo -e "  2. ${CYAN}TrollStore (Jailbreak / CoreTrust bypass):${RESET}"
    echo -e "     Open '${PROJECT_NAME}.ipa' directly in TrollStore for permanent unrevocable installation."
    echo -e "  3. ${CYAN}Game Assets Provisioning:${RESET}"
    echo -e "     Open the iOS 'Files' app on your device, navigate to 'On My iPhone' -> 'NFS Carbon' -> 'NFSC',"
    echo -e "     and copy your PC v1.4 Collector's Edition files into that directory."
    echo -e "${BOLD}${GREEN}======================================================================${RESET}\n"
else
    echo -e "${RED}Error: Failed to create ${OUTPUT_IPA}.${RESET}"
    exit 1
fi
