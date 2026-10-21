#!/usr/bin/env python3
"""
Advance PC by 4 on guest thread read faults (e.g. 0x70000002) in the POSIX/Mach signal handler.

    python3 tools/ios/patch_ios_signal_handler.py            apply
    python3 tools/ios/patch_ios_signal_handler.py --status
    python3 tools/ios/patch_ios_signal_handler.py --revert

Touches src/core/exception_handler_posix.cpp.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from patch_engine import run  # noqa: E402

FILE = "src/core/exception_handler_posix.cpp"

CB_ANCHOR = '''static void ExceptionHandlerCallback(int signal_number, siginfo_t* signal_info,
                                     void* signal_context) {
#if REX_PLATFORM_MAC
  // Darwin's mcontext_t is already a pointer (__darwin_mcontext64*); copy it.
  mcontext_t mcontext = reinterpret_cast<ucontext_t*>(signal_context)->uc_mcontext;
#else
'''

CB_NEW = '''#if defined(__APPLE__) || REX_PLATFORM_IOS || REX_PLATFORM_MAC
#include <sys/mman.h>
#endif

static void ExceptionHandlerCallback(int signal_number, siginfo_t* signal_info,
                                     void* signal_context) {
#if REX_PLATFORM_MAC
  // Darwin's mcontext_t is already a pointer (__darwin_mcontext64*); copy it.
  mcontext_t mcontext = reinterpret_cast<ucontext_t*>(signal_context)->uc_mcontext;
#if (defined(__arm64__) || defined(__aarch64__))
  // LOCAL PATCH - iOS (tools/ios/patch_ios_signal_handler.py):
  // Bypass 0x70000002 / unmapped guest memory read faults by advancing PC by 4
  uintptr_t fault_addr = reinterpret_cast<uintptr_t>(signal_info ? signal_info->si_addr : 0);
  uint64_t guest_offset = fault_addr & 0xFFFFFFFFULL;
  bool is_guest_fault = (fault_addr == 0x70000002) || 
                        (fault_addr >= 0x40000000 && fault_addr < 0x80000000) ||
                        (guest_offset == 0x70000002) ||
                        (guest_offset >= 0x40000000 && guest_offset < 0x80000000);
  if (is_guest_fault) {
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64
    mcontext->__ss.__opaque_pc = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(mcontext->__ss.__opaque_pc) + 4);
#else
    mcontext->__ss.__pc += 4;
#endif
    return;
  }

  // 2. Handle write protection faults on PE header / image pages (0x82000000 - 0x830D0000)
  if (guest_offset >= 0x82000000 && guest_offset < 0x830D0000) {
    uintptr_t page_addr_16k = fault_addr & ~((uintptr_t)16383ULL);
    if (mprotect(reinterpret_cast<void*>(page_addr_16k), 16384, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
      return; // Retry instruction with write access granted
    }
    uintptr_t page_addr_4k = fault_addr & ~((uintptr_t)4095ULL);
    if (mprotect(reinterpret_cast<void*>(page_addr_4k), 4096, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
      return; // Retry instruction with write access granted
    }
    // If mprotect fails, step the ARM64 instruction pointer forward by 4 bytes
#if __DARWIN_OPAQUE_ARM_THREAD_STATE64
    mcontext->__ss.__opaque_pc = reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(mcontext->__ss.__opaque_pc) + 4);
#else
    mcontext->__ss.__pc += 4;
#endif
    return;
  }
#endif
#else
'''

BLOCKS = [
    (FILE, "advance PC by 4 on guest thread read faults", CB_ANCHOR, CB_NEW),
]

if __name__ == "__main__":
    sys.exit(run("ios_signal_handler", BLOCKS))
