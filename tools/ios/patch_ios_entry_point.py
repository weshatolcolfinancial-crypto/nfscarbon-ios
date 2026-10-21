#!/usr/bin/env python3
"""
NFS Carbon entry point fix:
Xbox 360 NFS Carbon (Title ID 0x454107EC) retail disc XEX headers contain
entry_point = 0x829446E0, which is an immediate return stub (epilogue of a
wrapper), causing the main thread and game to terminate instantly.
The true CRT entry point is xstart at 0x82944510.

    python3 tools/ios/patch_ios_entry_point.py            apply
    python3 tools/ios/patch_ios_entry_point.py --status
    python3 tools/ios/patch_ios_entry_point.py --revert

Touches include/rex/system/user_module.h, src/system/user_module.cpp and src/system/kernel_state.cpp.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from patch_engine import run  # noqa: E402

H_FILE = "include/rex/system/user_module.h"
CPP_FILE = "src/system/user_module.cpp"
KS_FILE = "src/system/kernel_state.cpp"

H_ANCHOR = '''  uint32_t entry_point() const { return entry_point_; }
  uint32_t stack_size() const { return stack_size_; }
'''
H_NEW = '''  uint32_t entry_point() const { return entry_point_; }
  void set_entry_point(uint32_t ep) { entry_point_ = ep; }
  uint32_t stack_size() const { return stack_size_; }
'''

CPP_ANCHOR = '''  // Cache some commonly used headers...
  this->xex_module()->GetOptHeader(XEX_HEADER_ENTRY_POINT, &entry_point_);
  this->xex_module()->GetOptHeader(XEX_HEADER_DEFAULT_STACK_SIZE, &stack_size_);
'''
CPP_NEW = '''  // Cache some commonly used headers...
  this->xex_module()->GetOptHeader(XEX_HEADER_ENTRY_POINT, &entry_point_);
  // LOCAL PATCH - iOS: NFS Carbon (0x454107EC) retail disc XEX entry point fix.
  // Retail default.xex specifies 0x829446E0 which is an immediate return stub
  // (function epilogue). The actual CRT entry point is xstart at 0x82944510.
  if (entry_point_ == 0x829446E0 || (title_id() == 0x454107EC && entry_point_ != 0x82944510)) {
    entry_point_ = 0x82944510;
  }
  this->xex_module()->GetOptHeader(XEX_HEADER_DEFAULT_STACK_SIZE, &stack_size_);
'''

KS_ANCHOR = '''  // Create a thread to run in.
  // We start suspended so the caller can inspect/attach before resume.
  auto thread = object_ref<XThread>(new XThread(
      this, module->stack_size(), 0, module->entry_point(), 0, X_CREATE_SUSPENDED, true, true));
'''
KS_NEW = '''  // LOCAL PATCH - iOS: NFS Carbon (0x454107EC) retail disc XEX entry point fix.
  uint32_t ep = module->entry_point();
  if (ep == 0x829446E0 || (module->title_id() == 0x454107EC && ep != 0x82944510)) {
    REXSYS_INFO("[ios] Overriding module entry point 0x{:08X} -> 0x82944510 (xstart)", ep);
    ep = 0x82944510;
  }

#if defined(__APPLE__) || REX_PLATFORM_IOS
#include <sys/mman.h>
  // Ensure main image memory (0x82000000 - 0x830D0000) has write permissions (PE header zeroing)
  if (auto* mem = memory()) {
    uint8_t* host_img_base = reinterpret_cast<uint8_t*>(mem->virtual_membase() + 0x82000000ULL);
    size_t img_size = 0x010D0000;
    mprotect(host_img_base, img_size, PROT_READ | PROT_WRITE | PROT_EXEC);
  }
#endif

  // Create a thread to run in.
  // We start suspended so the caller can inspect/attach before resume.
  auto thread = object_ref<XThread>(new XThread(
      this, module->stack_size(), 0, ep, 0, X_CREATE_SUSPENDED, true, true));
'''

BLOCKS = [
    (H_FILE, "UserModule set_entry_point setter", H_ANCHOR, H_NEW),
    (CPP_FILE, "UserModule entry_point override for NFS Carbon", CPP_ANCHOR, CPP_NEW),
    (KS_FILE, "KernelState launch thread entry point override for NFS Carbon", KS_ANCHOR, KS_NEW),
]

if __name__ == "__main__":
    sys.exit(run("ios_entry_point", BLOCKS))
