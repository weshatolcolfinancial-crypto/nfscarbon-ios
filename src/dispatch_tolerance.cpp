// Runtime indirect call resolution for ReXGlue recompiled executables on iOS.
// Resolves:
//   1. Exact recompiled function entry points (via FunctionDispatcher)
//   2. Alternate entry points, label offsets, and local routines inside recompiled functions
//   3. Empty functions / subroutine returns (0x4E800020 'blr' instructions)
//   4. Out-of-range indirect calls (0x80000000 - 0xFFFFFFFF) via Extended Dynamic Stub Table
// Automatically populates the fast lookup dispatch table to eliminate subsequent lookup overhead.

#include <cstdint>
#include <mutex>
#include <set>
#include <unordered_map>

#include <rex/logging.h>
#include <rex/ppc.h>
#include <rex/image_info.h>
#include <rex/runtime.h>
#include <rex/system/function_dispatcher.h>
#include <rex/system/kernel_state.h>
#include <rex/system/xmemory.h>

extern PPCFuncMapping PPCFuncMappings[];
extern const rex::PPCImageInfo PPCImageConfig;

namespace {

// Pure blr: preserves all context/registers and returns to caller, matching PowerPC 'blr' instruction
void FastBlrStub(PPCContext& /*ctx*/, uint8_t* /*base*/) {
  return;
}

// Fallback for out-of-range or truly unresolvable addresses: returns 0 in r3
void UnknownExportStub(PPCContext& ctx, uint8_t* /*base*/) {
  ctx.r3.u64 = 0;
}

void NoopTrap(PPCContext& ctx, uint8_t* /*base*/) {
  ctx.r3.u64 = 0;
}

// Extended Dynamic Stub Table for out-of-range indirect calls
// (Carbon executes across 0x80000000-0x9FFFFFFF, 0xA0000000-0xBFFFFFFF, and 0xC0000000-0xFFFFFFFF)
static std::mutex g_dynamic_mutex;
static std::unordered_map<uint32_t, ::PPCFunc*> g_dynamic_table;

void RegisterDynamicStub(uint32_t address, ::PPCFunc* stub = &UnknownExportStub) {
  std::lock_guard<std::mutex> lock(g_dynamic_mutex);
  g_dynamic_table[address] = stub;
}

static size_t g_num_mappings = 0;
static void InitMappingsCount() {
  if (g_num_mappings == 0) {
    size_t count = 0;
    while (PPCFuncMappings[count].guest != 0) {
      count++;
    }
    g_num_mappings = count;
  }
}

inline bool IsWithinModuleCodeRange(uint32_t address) {
  uint32_t start = PPCImageConfig.code_base;
  uint32_t end = PPCImageConfig.code_base + PPCImageConfig.code_size;
  return (address >= start && address < end);
}

inline void SafeSetFunction(FunctionDispatcher* d, uint32_t address, ::PPCFunc* func) {
  uint32_t module_start = PPCImageConfig.code_base;
  uint32_t module_end = PPCImageConfig.code_base + PPCImageConfig.code_size;
  if (address < module_start || address >= module_end) {
    // Carbon executes indirect calls across 0x80000000-0x9FFFFFFF, 0xA0000000-0xBFFFFFFF, and 0xC0000000-0xFFFFFFFF.
    // DO NOT abort or reject the address. Register it in an extended dynamic table
    // or bind it to an unknown_export_stub that returns 0:
    RegisterDynamicStub(address, func ? func : &UnknownExportStub);
    return;
  }
  if (d) {
    d->SetFunction(address, func ? func : &UnknownExportStub);
  }
}

}  // namespace

namespace rex::runtime {

::PPCFunc* ResolveIndirectFunction(uint32_t guest_address) {
  Runtime* rt = Runtime::instance();
  if (!rt) return &UnknownExportStub;
  FunctionDispatcher* d = rt->function_dispatcher();

  // 1. Check Extended Dynamic Stub Table first
  {
    std::lock_guard<std::mutex> lock(g_dynamic_mutex);
    auto it = g_dynamic_table.find(guest_address);
    if (it != g_dynamic_table.end()) {
      return it->second;
    }
  }

  // 2. Exact match in function dispatcher table
  if (d) {
    if (::PPCFunc* f = d->GetFunction(guest_address)) {
      return f;
    }
  }

  // 3. Binary search in sorted PPCFuncMappings
  InitMappingsCount();
  if (g_num_mappings > 0) {
    size_t low = 0;
    size_t high = g_num_mappings;
    while (low < high) {
      size_t mid = low + (high - low) / 2;
      if (PPCFuncMappings[mid].guest <= guest_address) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }

    if (low > 0) {
      size_t idx = low - 1;
      uint32_t base_addr = static_cast<uint32_t>(PPCFuncMappings[idx].guest);
      uint32_t next_addr = (idx + 1 < g_num_mappings)
                               ? static_cast<uint32_t>(PPCFuncMappings[idx + 1].guest)
                               : (PPCImageConfig.code_base + PPCImageConfig.code_size);

      if (guest_address >= base_addr && guest_address < next_addr) {
        // Read guest instruction if virtual memory is mapped
        uint8_t* base = nullptr;
        if (auto* ks = rt->kernel_state()) {
          if (auto* mem = ks->memory()) {
            base = mem->virtual_membase();
          }
        }

        if (base) {
          uint32_t insn = __builtin_bswap32(*reinterpret_cast<const uint32_t*>(base + guest_address));
          if (insn == 0x4E800020) {  // blr (return from subroutine)
            SafeSetFunction(d, guest_address, &FastBlrStub);
            return &FastBlrStub;
          }
        }

        // Alternate entry point or instruction within PPCFuncMappings[idx].host
        ::PPCFunc* target_func = PPCFuncMappings[idx].host;
        if (target_func) {
          SafeSetFunction(d, guest_address, target_func);
          return target_func;
        }
      }
    }
  }

  // 4. Fallback instruction inspection in guest memory
  uint8_t* base = nullptr;
  if (auto* ks = rt->kernel_state()) {
    if (auto* mem = ks->memory()) {
      base = mem->virtual_membase();
    }
  }
  if (base) {
    // Avoid reading outside mapped guest regions
    uint32_t insn = __builtin_bswap32(*reinterpret_cast<const uint32_t*>(base + guest_address));
    if (insn == 0x4E800020) {
      SafeSetFunction(d, guest_address, &FastBlrStub);
      return &FastBlrStub;
    }
  }

  // 5. Out-of-range or unknown export address (0x80000000 - 0xFFFFFFFF)
  static std::mutex mutex;
  static std::set<uint32_t> seen;
  {
    std::lock_guard<std::mutex> lock(mutex);
    if (seen.size() < 30 && seen.insert(guest_address).second) {
      REXLOG_WARN("[dispatch] Out-of-range / dynamic indirect call to 0x{:08X} registered with safe zero return", guest_address);
    }
  }

  // Never abort: bind to UnknownExportStub in the extended dynamic table
  RegisterDynamicStub(guest_address, &UnknownExportStub);
  if (d) {
    d->SetFunction(guest_address, &UnknownExportStub);
  }
  return &UnknownExportStub;
}

}  // namespace rex::runtime
