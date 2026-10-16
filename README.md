# Need for Speed: Carbon (Xbox 360) Recompiled for iOS

**Need for Speed: Carbon (Xbox 360 release), statically recompiled to run natively on iPhone and iPad with 60 FPS support, touch controls, and controller integration.**

This is **not an emulator**. The game's PowerPC Xenon machine code is translated ahead-of-time into native C++ using the **ReXGlue SDK** and compiled directly for Apple Silicon (`arm64`). The Xbox 360's ATI Xenos GPU commands are translated into Vulkan and rendered through Metal via MoltenVK.

---

## Features

- **Native Apple Silicon execution**: Native ARM64 binary compiled directly for modern iPhones and iPads.
- **High Performance**: Target locked 60 FPS with frame rate capping options (30, 40, 60, 120 FPS for ProMotion).
- **Controls**:
  - Full on-screen touch layout (steering wheel/arrows, gas, brake, nitrous, speedbreaker, handbrake, reset, pause).
  - Native controller support (Xbox, DualSense, MFi gamepads via Apple's GameController framework).
- **Audio**: Multi-channel streaming audio adapted for iOS CoreAudio.
- **Display**: Widescreen support with custom safe-area handling for notched and Dynamic Island devices.
- **Saves**: Saves are retained directly in the app's `Documents/` folder.

---

## Requirements

### To Play:
- An iPhone or iPad running **iOS 16.0 or newer** (A14 Bionic / M1 or newer recommended for optimal frame rates).
- Sideloading utility: **[LiveContainer](https://github.com/LiveContainer/LiveContainer)**, **[SideStore](https://sidestore.io)**, or AltStore/TrollStore.
- A legal copy of **Need for Speed: Carbon (Xbox 360 edition)**.

### To Build:
- macOS with **Xcode 15+** (Apple Silicon or Intel), or use the included **GitHub Actions workflow**.
- Python 3.9+ and CMake 3.25+ (`brew install cmake ninja`).
- ~25 GB free disk space.

---

## Quick Start: Building the IPA

### Option A: Automated Build with GitHub Actions (No Mac Needed)
1. Fork or push this repository to your GitHub account.
2. Go to **Actions** $\to$ **Build iOS IPA**.
3. (Optional) Commit your `default.xex` to `game/default.xex` if you want GitHub Actions to compile the full game code ahead-of-time.
4. Click **Run workflow**. Once finished, download `NFSCarbon.ipa` from the workflow artifacts!

---

### Option B: Building Locally on a Mac

```sh
# 1. Clone this repository
git clone https://github.com/your-username/nfscarbon-ios.git
cd nfscarbon-ios

# 2. Prepare the ReXGlue SDK & download MoltenVK for iOS
python3 tools/prepare_sdk.py

# 3. Extract the game's executable from your Xbox 360 ISO into game/default.xex
python3 tools/extract_iso.py "/path/to/NFS_Carbon_Xbox360.iso" --solo-xex -o game

# 4. Generate the native C++ code
python3 tools/generate_code.py --xex game/default.xex

# 5. Configure and build the .ipa
cd ios
cmake --preset ios
cmake --build --preset ios --target ipa
```

The resulting `NFSCarbon.ipa` will be output to `ios/build/NFSCarbon.ipa`.

---

## Installing and Playing on Device

1. Sideload `NFSCarbon.ipa` using **LiveContainer**, **SideStore**, **TrollStore**, or **AltStore**.
2. Open the app once to initialize the directory structure (this creates `Documents/game/`, `Documents/logs/`, and `Documents/data/`).
3. **Supplying Game Files (Two Easy Options):**
   - **Option A (Automatic Detection, like NFSU2):** Using the iOS **Files** app ("On My iPhone" $\to$ "NFS Carbon"), or LiveContainer's file manager, copy your retail Xbox 360 NFS Carbon ISO or extracted game files directly into the **`Documents/game/`** folder! The app automatically discovers and selects them on launch.
   - **Option B (In-App Picker):** Tap **"Select / Import Game (ISO or Folder)..."** directly on the launch screen to browse and select any `.iso` or game folder from Files, iCloud, or external storage.
4. Adjust your resolution and graphic options, and tap **Play**!

---

## Repository Structure

```
├── .github/workflows/
│   └── build-ios.yml          # GitHub Actions automated IPA builder
├── ios/
│   ├── CMakeLists.txt         # iOS app build & IPA packaging target
│   ├── CMakePresets.json      # iOS arm64 build presets
│   ├── Info.plist.in          # App bundle metadata & controller config
│   ├── nfscarbon.entitlements # Mach memory & execution entitlements
│   └── src/                   # iOS launcher, UIKit lifecycle, touch controls, audio
├── src/                       # Carbon-specific engine & render mode hooks
├── renderer/                  # Carbon Vulkan GPU pipeline optimizations
├── tools/
│   ├── extract_iso.py         # Standalone Xbox 360 ISO extractor
│   ├── prepare_sdk.py         # ReXGlue iOS SDK setup & MoltenVK downloader
│   └── generate_code.py       # Ahead-of-time PowerPC-to-C++ code generator
└── nfscarbon_manifest.toml    # ReXGlue project manifest & function entrypoints
```

---

## Credits & Acknowledgments

- **[ReXGlue SDK](https://github.com/rexglue/rexglue-sdk)**: Static recompilation SDK for Xbox 360 binaries.
- **[bep1s69/nfsmw-ios](https://github.com/bep1s69/nfsmw-ios)**: The pioneering Xbox 360 iOS platform harness and Mach memory sandbox implementation.
- **[Sampreeth004/nfs-carbon-recomp](https://github.com/Sampreeth004/nfs-carbon-recomp)**: NFS Carbon Xbox 360 function mappings, manifest, and renderer optimizations.
- **[KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK)**: Vulkan implementation on Apple's Metal graphics framework.
