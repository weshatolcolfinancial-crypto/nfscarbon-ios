#!/usr/bin/env python3
"""
generate_icon.py - Root wrapper for tools/ios/generate_icon.py
"""
import os
import sys

script_dir = os.path.dirname(os.path.abspath(__file__))
ios_script = os.path.join(script_dir, "tools", "ios", "generate_icon.py")

if __name__ == "__main__":
    if os.path.exists(ios_script):
        # Execute the main generator
        exec(open(ios_script).read())
    else:
        print(f"Error: {ios_script} not found")
        sys.exit(1)
