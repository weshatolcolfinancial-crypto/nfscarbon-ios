#!/usr/bin/env python3
"""
Generates Need for Speed: Carbon C++ source code for iOS using the ReXGlue SDK.

    python tools/generate_code.py
    python tools/generate_code.py --xex /path/to/default.xex

Requirements:
  - iOS SDK prepared: python tools/prepare_sdk.py
  - Xbox 360 default.xex in game/default.xex (or passed with --xex)
  - CMake and Ninja (brew install cmake ninja)
"""

import argparse
import os
import pathlib
import platform
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "nfscarbon_manifest.toml"
DEFAULT_XEX = ROOT / "game" / "default.xex"
GENERATED = ROOT / "ios" / "generated" / "default"


def fail(msg):
    sys.exit(f"[ERROR] {msg}")


def build_cli(sdk):
    for tool in ("cmake", "ninja", "clang++"):
        if not shutil.which(tool):
            fail(f"Cannot find '{tool}' in PATH. Ensure Xcode and cmake/ninja are installed.")
    if platform.system() != "Darwin":
        fail("ReXGlue code generator must run on macOS (Apple Silicon or Intel) or via GitHub Actions runner.")
    preset = "mac-arm64" if platform.machine() == "arm64" else "mac-amd64"
    print(f"== Building rexglue CLI from iOS SDK ({preset})")
    if subprocess.run(["cmake", "--preset", preset], cwd=sdk).returncode != 0:
        fail("Configuring ReXGlue SDK for Mac failed.")
    if subprocess.run(["cmake", "--build", f"out/build/{preset}", "--config", "Release",
                       "--target", "rexglue"], cwd=sdk).returncode != 0:
        fail("Building rexglue CLI failed.")
    
    candidates = sorted((sdk / "out").rglob("rexglue"), key=lambda p: p.stat().st_mtime, reverse=True)
    candidates = [c for c in candidates if c.is_file() and os.access(c, os.X_OK)]
    if not candidates:
        fail(f"Built, but cannot find rexglue executable under {sdk / 'out'}")
    return candidates[0]


def main():
    ap = argparse.ArgumentParser(description="Generates NFS Carbon C++ code for iOS.")
    ap.add_argument("--sdk", default=str(ROOT.parent / "rexglue-sdk-ios"),
                    help="Path to prepared ReXGlue SDK")
    ap.add_argument("--xex", default=str(DEFAULT_XEX),
                    help="Path to NFS Carbon Xbox 360 default.xex")
    ap.add_argument("--rexglue", default=None,
                    help="Path to an existing rexglue CLI executable")
    args = ap.parse_args()

    sdk = pathlib.Path(args.sdk).resolve()
    xex = pathlib.Path(args.xex).resolve()

    if not (sdk / "include" / "rex" / "platform.h").is_file():
        fail(f"No ReXGlue SDK found in {sdk}. Run first: python tools/prepare_sdk.py")
    if not xex.is_file():
        fail(f"Cannot find '{xex}'. Please extract default.xex from your NFS Carbon (Xbox 360) ISO to game/default.xex")

    GENERATED.mkdir(parents=True, exist_ok=True)

    rexglue = pathlib.Path(args.rexglue).resolve() if args.rexglue else build_cli(sdk)
    print(f"[ok] Using rexglue CLI: {rexglue}")

    # Prepare temporary manifest pointing directly to the user's default.xex and output dir
    manifest_content = MANIFEST.read_text(encoding="utf-8")
    rel_xex = os.path.relpath(xex, ROOT).replace("\\", "/")
    rel_out = os.path.relpath(GENERATED, ROOT).replace("\\", "/")
    
    # Update entrypoint file_path and out_directory_path
    lines = []
    for line in manifest_content.splitlines():
        if line.startswith("file_path ="):
            lines.append(f'file_path = "{rel_xex}"')
        elif line.startswith("out_directory_path ="):
            lines.append(f'out_directory_path = "{rel_out}"')
        elif line.startswith("game_root ="):
            rel_game_root = os.path.relpath(xex.parent, ROOT).replace("\\", "/")
            lines.append(f'game_root = "{rel_game_root}"')
        else:
            lines.append(line)
            
    temp_manifest = ROOT / "nfscarbon_manifest_ios.toml"
    temp_manifest.write_text("\n".join(lines), encoding="utf-8")

    print("\n== Running Codegen for NFS Carbon")
    res = subprocess.run([str(rexglue), "codegen", str(temp_manifest.name)], cwd=ROOT)
    if res.returncode != 0:
        fail("ReXGlue codegen failed.")

    sources_cmake = GENERATED / "sources.cmake"
    if not sources_cmake.is_file():
        fail(f"Codegen completed but {sources_cmake} was not produced.")

    # Generate PCH if not present
    pch = GENERATED / "nfscarbon_pch.h"
    if not pch.is_file():
        pch.write_text("#pragma once\n#include <rex/runtime.h>\n", encoding="utf-8")

    cpp_count = sum(1 for _ in GENERATED.glob("*.cpp"))
    print(f"\n[SUCCESS] Generated {cpp_count} C++ files in {GENERATED}")
    print("Next step: Build the iOS app with CMake:")
    print("    cd ios && cmake --preset ios && cmake --build --preset ios --target ipa")
    return 0


if __name__ == "__main__":
    sys.exit(main())
