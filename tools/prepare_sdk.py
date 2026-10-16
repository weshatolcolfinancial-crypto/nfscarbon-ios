#!/usr/bin/env python3
"""
Convenience entry point to prepare the ReXGlue SDK for iOS.
Usage:
    python tools/prepare_sdk.py
"""
import subprocess
import sys
from pathlib import Path

if __name__ == "__main__":
    script = Path(__file__).resolve().parent / "ios" / "prepare_sdk.py"
    sys.exit(subprocess.call([sys.executable, str(script)] + sys.argv[1:]))
