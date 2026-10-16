// Runtime indirect call resolution for ReXGlue recompiled executables on iOS.
// Resolves:
//   1. Exact recompiled function entry points (via FunctionDispatcher)
//   2. Alternate entry points, label offsets, and local routines inside recompiled functions
//   3. Empty functions / subroutine returns (0x4E800020 'blr' instructions)
// Automatically populates the fast lookup dispatch table to eliminate subsequent lookup overhead.

#include <cstdint>
#include <mutex>
#include <set>

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

// Fallback for truly unresolvable addresses
void NoopTrap(PPCContext& ctx, uint8_t* /*base*/) {
  ctx.r3.u64 = 0;
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

}  // namespace

namespace rex::runtime {

::PPCFunc* ResolveIndirectFunction(uint32_t guest_address) {
  Runtime* rt = Runtime::instance();
  if (!rt) return &NoopTrap;
  FunctionDispatcher* d = rt->function_dispatcher();
  if (!d) return &NoopTrap;

  // 1. Exact match in function dispatcher table
  if (::PPCFunc* f = d->GetFunction(guest_address)) {
    return f;
  }

  // 2. Binary search in sorted PPCFuncMappings
  InitMappingsCount();
  if (g_num_mappings > 0) {
    // Upper bound to find the mapping with greatest guest <= guest_address
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
            d->SetFunction(guest_address, &FastBlrStub);
            return &FastBlrStub;
          }
        }

        // Alternate entry point or instruction within PPCFuncMappings[idx].host
        ::PPCFunc* target_func = PPCFuncMappings[idx].host;
        if (target_func) {
          d->SetFunction(guest_address, target_func);
          return target_func;
        }
      }
    }
  }

  // 3. Fallback instruction inspection in guest memory
  uint8_t* base = nullptr;
  if (auto* ks = rt->kernel_state()) {
    if (auto* mem = ks->memory()) {
      base = mem->virtual_membase();
    }
  }
  if (base) {
    uint32_t insn = __builtin_bswap32(*reinterpret_cast<const uint32_t*>(base + guest_address));
    if (insn == 0x4E800020) {
      d->SetFunction(guest_address, &FastBlrStub);
      return &FastBlrStub;
    }
  }

  // 4. Truly unresolvable call
  static std::mutex mutex;
  static std::set<uint32_t> seen;
  std::lock_guard<std::mutex> lock(mutex);
  if (seen.size() < 20 && seen.insert(guest_address).second) {
    REXLOG_WARN("[dispatch] Truly unregistered indirect call to 0x{:08X}", guest_address);
  }

  d->SetFunction(guest_address, &NoopTrap);
  return &NoopTrap;
}

}  // namespace rex::runtime
