// Sleep instead of spin while the game's D3D waits for ring space.
//
// When the GPU command ring is full, Carbon's D3D waits for the command
// processor (CP) to advance its read pointer. It does so by spinning:
// sub_826DBD78 and sub_826DBB80 reread the pointer in a loop and call the hang
// watchdog sub_826E0250 on every iteration (it returns 0 once the pointer has
// not moved for 5 s).
//
// Hook: if the read pointer has not moved since the watchdog's last look, pause
// until the CP publishes a new one, capped at 1 ms.
//
// Addresses and device offset re-derived for Carbon.

#include <dlfcn.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <ctime>
#include <thread>

#if defined(__linux__) || defined(__ANDROID__)
#include <linux/futex.h>
#include <sys/syscall.h>
#include <sys/system_properties.h>
#endif

#include "../generated/default/nfscarbon_pch.h"

extern "C" void __imp__sub_826E0250(PPCContext& __restrict ctx, uint8_t* base);

namespace {

// Return addresses of the watchdog calls in the two ring-space wait loops.
constexpr uint32_t kRingWaitReturn1 = 0x826DBE14;  // sub_826DBD78
constexpr uint32_t kRingWaitReturn2 = 0x826DBBF8;  // sub_826DBB80

// Offset in the D3D device of the pointer to the CP read pointer writeback
constexpr uint32_t kDeviceRptrPointer = 10768;

std::atomic<uint32_t>* RptrSequence() {
  static std::atomic<uint32_t>* const sequence = []() -> std::atomic<uint32_t>* {
#if defined(__ANDROID__)
    char value[PROP_VALUE_MAX] = {};
    if (__system_property_get("debug.nfscarbon.ring_wait", value) > 0 && value[0] == '0') {
      return nullptr;
    }
#endif
    for (const char* name : {"librexgpu-carbon.dylib", "librexgpu-xenos.dylib",
                             "librexgpu-carbon.so", "librexgpu-xenos.so"}) {
      if (void* plugin = dlopen(name, RTLD_NOW | RTLD_NOLOAD)) {
        if (void* symbol = dlsym(plugin, "nfsmw_cp_rptr_seq")) {
          return static_cast<std::atomic<uint32_t>*>(symbol);
        }
      }
    }
    return nullptr;
  }();
  return sequence;
}

}  // namespace

extern "C" REX_FUNC(sub_826E0250) {
  const uint32_t ret = uint32_t(ctx.lr);
  if (ret == kRingWaitReturn1 || ret == kRingWaitReturn2) {
    if (std::atomic<uint32_t>* sequence = RptrSequence()) {
      const uint32_t before = sequence->load(std::memory_order_acquire);
      const uint32_t state = ctx.r3.u32;
      const uint32_t device = REX_LOAD_U32(state + 0);
      const uint32_t seen = REX_LOAD_U32(state + 8);
      const uint32_t rptr = REX_LOAD_U32(REX_LOAD_U32(device + kDeviceRptrPointer));
      if (rptr == seen) {
#if defined(__linux__) || defined(__ANDROID__)
        timespec cap{0, 1000000};  // 1 ms
        syscall(SYS_futex, sequence, FUTEX_WAIT_PRIVATE, before, &cap, nullptr, 0);
#else
        std::this_thread::yield();
#endif
      }
    }
  }
  __imp__sub_826E0250(ctx, base);
}
