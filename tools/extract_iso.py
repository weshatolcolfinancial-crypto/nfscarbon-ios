#!/usr/bin/env python3
"""
Convenience ISO extraction tool for Need for Speed: Carbon Xbox 360 ISO.

Usage:
    python tools/extract_iso.py "/path/to/NFS_Carbon.iso" --solo-xex
    python tools/extract_iso.py "/path/to/NFS_Carbon.iso" -o game
"""
import subprocess
import sys
from pathlib import Path

if __name__ == "__main__":
    script = Path(__file__).resolve().parent / "fase1_extraer.py"
    sys.exit(subprocess.call([sys.executable, str(script)] + sys.argv[1:]))
