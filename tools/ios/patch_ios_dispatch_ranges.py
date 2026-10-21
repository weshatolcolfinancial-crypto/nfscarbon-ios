#!/usr/bin/env python3
"""
Support out-of-range indirect function calls across 0x80000000-0xFFFFFFFF
by dynamically registering stub bindings instead of asserting or aborting.

    python3 tools/ios/patch_ios_dispatch_ranges.py            apply
    python3 tools/ios/patch_ios_dispatch_ranges.py --status
    python3 tools/ios/patch_ios_dispatch_ranges.py --revert

Touches src/system/function_dispatcher.cpp.
"""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from patch_engine import run  # noqa: E402

FILE = "src/system/function_dispatcher.cpp"

STUB_ANCHOR = '''namespace rex::runtime {

namespace {
'''

STUB_NEW = '''namespace rex::runtime {

namespace {

// LOCAL PATCH - iOS (tools/ios/patch_ios_dispatch_ranges.py):
// Dynamic unknown export stub returning 0 (r3 = 0)
static void UnknownExportStub(PPCContext& ctx, uint8_t* /*base*/) {
  ctx.r3.u64 = 0;
}
'''

SET_FUNC_ANCHOR = '''bool FunctionDispatcher::SetFunction(uint32_t guest_address, ::PPCFunc* func) {
  std::lock_guard<std::recursive_mutex> lock(dispatch_mutex_);
  assert_true(!module_tables_.empty());

  if (!FindModuleByAddress(guest_address)) {
    REXLOG_ERROR("SetFunction: address {:08X} outside all registered module ranges", guest_address);
    return false;
  }

  function_table_[guest_address] = func;

  if (!memory_->SetFunction(guest_address, func)) {
    REXLOG_ERROR("SetFunction: dispatcher / Memory module-table state out of sync at {:08X}",
                 guest_address);
    function_table_.erase(guest_address);
    return false;
  }

  if (recording_) {
    recording_addresses_.push_back(guest_address);
  }
  return true;
}'''

SET_FUNC_NEW = '''bool FunctionDispatcher::SetFunction(uint32_t guest_address, ::PPCFunc* func) {
  std::lock_guard<std::recursive_mutex> lock(dispatch_mutex_);
  assert_true(!module_tables_.empty());

  // LOCAL PATCH - iOS (tools/ios/patch_ios_dispatch_ranges.py):
  // Carbon executes indirect calls across 0x80000000-0x9FFFFFFF, 0xA0000000-0xBFFFFFFF, and 0xC0000000-0xFFFFFFFF.
  // When address is outside registered module code range:
  // DO NOT abort or reject the address. Register it in an extended dynamic table
  // or bind it to an unknown_export_stub that returns 0.
  if (!FindModuleByAddress(guest_address)) {
    function_table_[guest_address] = func ? func : &UnknownExportStub;
    return true;
  }

  function_table_[guest_address] = func ? func : &UnknownExportStub;

  if (!memory_->SetFunction(guest_address, func ? func : &UnknownExportStub)) {
    // Keep in dispatcher function_table_ even if guest memory table cannot hold the address
    REXLOG_WARN("SetFunction: address {:08X} cached in dispatcher dynamic table", guest_address);
  }

  if (recording_) {
    recording_addresses_.push_back(guest_address);
  }
  return true;
}'''

RESOLVE_ANCHOR = '''PPCFunc* ResolveIndirectFunction(uint32_t guest_address) {
  FunctionDispatcher* dispatcher = GetBoundFunctionDispatcher();
  if (!dispatcher) {
    return &InvalidFunctionTrap;
  }

  if (PPCFunc* func = dispatcher->GetFunction(guest_address)) {
    return func;
  }

  return &InvalidFunctionTrap;
}'''

RESOLVE_NEW = '''PPCFunc* ResolveIndirectFunction(uint32_t guest_address) {
  FunctionDispatcher* dispatcher = GetBoundFunctionDispatcher();
  if (!dispatcher) {
    return &UnknownExportStub;
  }

  if (PPCFunc* func = dispatcher->GetFunction(guest_address)) {
    return func;
  }

  // LOCAL PATCH - iOS (tools/ios/patch_ios_dispatch_ranges.py):
  // Register unmapped address dynamically with UnknownExportStub (returns 0)
  dispatcher->SetFunction(guest_address, &UnknownExportStub);
  return &UnknownExportStub;
}'''

BLOCKS = [
    (FILE, "define UnknownExportStub", STUB_ANCHOR, STUB_NEW),
    (FILE, "dynamic registration for out-of-range SetFunction", SET_FUNC_ANCHOR, SET_FUNC_NEW),
    (FILE, "safe ResolveIndirectFunction with UnknownExportStub fallback", RESOLVE_ANCHOR, RESOLVE_NEW),
]

if __name__ == "__main__":
    sys.exit(run("ios_dispatch_ranges", BLOCKS))
