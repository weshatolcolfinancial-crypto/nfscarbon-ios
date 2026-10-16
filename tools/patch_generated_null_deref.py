#!/usr/bin/env python3
"""
Patch generated ReXGlue C++ code in ios/generated/default/ to guard against
null pointer dereferences when iterating uninitialized or zero-filled linked
list / hash table bucket heads (e.g. during CRT _initterm startup).
"""

import os
import re

GEN_DIR = os.path.join(os.path.dirname(__file__), "..", "ios", "generated", "default")

# Pattern 1: Bucket array traversal
p1 = re.compile(
    r'(// lwz r11,0\(r8\)\s*\n'
    r'\s*ctx\.r11\.u64 = REX_LOAD_U32\(ctx\.r8\.u32 \+ 0\);\s*\n'
    r'\s*// cmplw cr6,r11,r8\s*\n'
    r'\s*ctx\.cr6\.compare<uint32_t>\(ctx\.r11\.u32, ctx\.r8\.u32, ctx\.xer\);\s*\n'
    r'\s*// beq cr6,[^\n]+\n)'
    r'(\s*if \(ctx\.cr6\.eq\) goto ([A-Za-z0-9_]+);)'
)

def repl1(m):
    head = m.group(1)
    target = m.group(3)
    return f"{head}\tif (ctx.cr6.eq || ctx.r11.u32 == 0) goto {target};"

# Pattern 1b: Inner loop null check before loading next node
# loc_...:
#   // mr rX,r11
#   ctx.rX.u64 = ctx.r11.u64;
#   // lwz r11,0(r11)
#   ctx.r11.u64 = REX_LOAD_U32(ctx.r11.u32 + 0);
#   // cmplw cr6,r11,r8
p1_inner = re.compile(
    r'(\t// mr r(9|10),r11\s*\n'
    r'\tctx\.r\2\.u64 = ctx\.r11\.u64;\s*\n)'
    r'(\t// lwz r11,0\(r11\)\s*\n'
    r'\tctx\.r11\.u64 = REX_LOAD_U32\(ctx\.r11\.u32 \+ 0\);\s*\n'
    r'\t// cmplw cr6,r11,r8)'
)

def repl1_inner(m):
    head = m.group(1)
    rest = m.group(3)
    return f"{head}\tif (ctx.r11.u32 == 0) return;\n{rest}"

def main():
    gen_dir = os.path.abspath(GEN_DIR)
    print(f"Scanning {gen_dir}...")
    p1_count = 0
    p1_inner_count = 0
    files_modified = 0

    for fname in sorted(os.listdir(gen_dir)):
        if not fname.endswith(".cpp"):
            continue
        path = os.path.join(gen_dir, fname)
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        new_content, c1 = p1.subn(repl1, content)
        new_content, c_inner = p1_inner.subn(repl1_inner, new_content)

        if c1 > 0 or c_inner > 0:
            files_modified += 1
            p1_count += c1
            p1_inner_count += c_inner
            with open(path, "w", encoding="utf-8") as f:
                f.write(new_content)
            print(f"  {fname}: patched {c1} bucket heads, {c_inner} inner loops")

    print(f"Done! Modified {files_modified} files (Bucket heads: {p1_count}, Inner loops: {p1_inner_count})")

if __name__ == "__main__":
    main()
