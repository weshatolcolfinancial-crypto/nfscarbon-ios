// NFS Carbon Recompiled - the app on iOS
//
// Native iOS application implementation for NFS Carbon:
//   - audio through CoreAudio (audio/coreaudio_driver.mm)
//   - on-screen touch controls (touch_controls.mm)
//   - GPU emulation lifecycle and background suspension
//   - ProMotion display refresh rate matching

#include "nfscarbon_init.h"
#include "nfscarbon_app.h"

#include <rex/logging.h>
#include <rex/runtime.h>
#include <rex/system/kernel_state.h>
#include <rex/system/user_module.h>
#include <rex/system/interfaces/graphics.h>

#include "achievements_export.h"
#include "audio/coreaudio_driver.h"
#include "display_rate.h"
#include "gpu_capture.h"
#include "boot_trace.h"
#include "launcher.h"
#include "lifecycle.h"

// The UI thread's paints stopped while paused
extern "C" void nfsmw_ios_suspend_paints(bool suspend) __attribute__((weak));
#include "touch_controls.h"

#include <rex/cvar.h>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <cstring>

REXCVAR_DECLARE(bool, ios_gpu_capture);  // ios_main.mm
REXCVAR_DECLARE(int32_t, ios_fps_cap);    // runtime present pacing

REXCVAR_DEFINE_BOOL(ios_touch_controls, true, "Input",
                    "iOS: on-screen touch controls (they hide themselves while a physical "
                    "controller is connected)");
REXCVAR_DEFINE_BOOL(ios_show_fps, true, "Display",
                    "iOS: frames per second and ms per frame in the top-left corner");

#if defined(__APPLE__)
#include <sys/mman.h>
#endif

namespace rex::runtime {
::PPCFunc* ResolveIndirectFunction(uint32_t guest_address);
}

// Strong symbol override for sub_82470EA8 to prevent null-dereference crash during CRT _initterm
extern "C" REX_FUNC(sub_82470EA8) {
  REX_FUNC_PROLOGUE();
  ctx.cr6.compare<uint32_t>(ctx.r4.u32, ctx.r5.u32, ctx.xer);
  if (!ctx.cr6.lt) return;
  ctx.r11.u64 = ctx.r5.u64 - ctx.r4.u64;
  ctx.r10.s64 = -1431699456;
  ctx.r11.s64 = ctx.r11.s64 + -1;
  ctx.r10.u64 = ctx.r10.u64 | 43691;
  ctx.r7.s64 = -2100822016;
  ctx.r11.u64 = (uint64_t(ctx.r11.u32) * uint64_t(ctx.r10.u32)) >> 32;
  ctx.r9.u64 = REX_LOAD_U32(ctx.r7.u32 + -21496);
  ctx.r11.u64 = __builtin_rotateleft64(ctx.r11.u32 | (ctx.r11.u64 << 32), 27) & 0x7FFFFFF;
  ctx.r8.s64 = ctx.r4.s64 + 32;
  ctx.r6.s64 = ctx.r11.s64 + 1;
loc_82470ED8:
  ctx.r11.u64 = REX_LOAD_U32(ctx.r8.u32 + 0);
  ctx.cr6.compare<uint32_t>(ctx.r11.u32, ctx.r8.u32, ctx.xer);
  if (ctx.cr6.eq || ctx.r11.u32 == 0) goto loc_82470F00;
loc_82470EE4:
  if (ctx.r11.u32 == 0) goto loc_82470F00;
  ctx.r10.u64 = ctx.r11.u64;
  ctx.r11.u64 = REX_LOAD_U32(ctx.r11.u32 + 0);
  ctx.cr6.compare<uint32_t>(ctx.r11.u32, ctx.r8.u32, ctx.xer);
  REX_STORE_U32(ctx.r10.u32 + 0, ctx.r9.u32);
  ctx.r9.u64 = ctx.r10.u64;
  REX_STORE_U32(ctx.r7.u32 + -21496, ctx.r9.u32);
  if (!ctx.cr6.eq && ctx.r11.u32 != 0) goto loc_82470EE4;
loc_82470F00:
  ctx.r6.s64 = ctx.r6.s64 + -1;
  ctx.r8.s64 = ctx.r8.s64 + 48;
  ctx.cr6.compare<uint32_t>(ctx.r6.u32, 0, ctx.xer);
  if (!ctx.cr6.eq) goto loc_82470ED8;
  return;
}

class IosNfsCarbonApp : public NfsCarbonApp {
 public:
  using NfsCarbonApp::NfsCarbonApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<IosNfsCarbonApp>(new IosNfsCarbonApp(ctx, "nfscarbon", PPCImageConfig));
  }

 protected:
  void OnPreSetup(rex::RuntimeConfig& config) override {
    NfsCarbonApp::OnPreSetup(config);
    config.audio_factory = REX_AUDIO_BACKEND(rex::audio::ios::CoreAudioSystem);
    config.gpu_plugin = "xenos";
  }

  void OnPreLaunchModule() override {
    NfsCarbonApp::OnPreLaunchModule();
    if (auto* rt = runtime()) {
      if (auto* ks = rt->kernel_state()) {
        if (auto mod = ks->GetExecutableModule()) {
          const uint32_t ep = mod->entry_point();
          if (ep == 0x829446E0 || (mod->title_id() == 0x454107EC && ep != 0x82944510)) {
            mod->set_entry_point(0x82944510);
            REXLOG_INFO("[ios] PreLaunchModule: overridden entry point 0x{:08X} -> 0x82944510 (xstart)", ep);
          } else {
            REXLOG_INFO("[ios] PreLaunchModule: title=0x{:08X}, entry_point=0x{:08X}",
                        mod->title_id(), ep);
          }
        }
        if (auto* mem = ks->memory()) {
          uint8_t* base = mem->virtual_membase();
          if (base) {
#if defined(__APPLE__)
            void* ptr = mmap(base, 0x10000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
            if (ptr != MAP_FAILED) {
              std::memset(ptr, 0, 0x10000);
              REXLOG_INFO("[ios] Mapped safe zero page at guest 0x00000000 (host {:p}, size 64KB)", ptr);
            } else {
              REXLOG_WARN("[ios] Failed to map safe zero page at {:p}: errno {}", (void*)base, errno);
            }

            // Map guest high addresses (0x40000000 to 0x7FFFFFFF) as non-faulting zero memory
            void* high_arena = mmap(base + 0x40000000ULL, 0x40000000ULL, PROT_READ | PROT_WRITE, 
                                    MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
            if (high_arena == MAP_FAILED) {
              REXLOG_ERROR("[ios] Failed to map guest high memory arena at {:p}: errno {}", (void*)(base + 0x40000000ULL), errno);
            } else {
              std::memset(high_arena, 0, 0x40000000ULL);
              REXLOG_INFO("[ios] Successfully mapped guest upper memory at host {:p}", high_arena);
            }

            // Enable write permissions on main image memory (0x82000000 - 0x830D0000)
            // for PE header zeroing and self-modifying code
            uint8_t* host_img_base = (uint8_t*)(base + 0x82000000ULL);
            size_t img_size = 0x010D0000; // Covers image range up to 0x830D0000
            if (mprotect(host_img_base, img_size, PROT_READ | PROT_WRITE | PROT_EXEC) == 0) {
              REXLOG_INFO("[ios] Enabled PROT_WRITE on main image range at {:p} (size 0x{:X})", (void*)host_img_base, img_size);
            } else {
              REXLOG_WARN("[ios] Failed to mprotect main image range at {:p}: errno {}", (void*)host_img_base, errno);
            }
#endif
            // Pre-resolve CRT static constructor and initializer tables to accelerate _initterm
            auto WarmupTable = [&](uint32_t start_addr, uint32_t end_addr) {
              uint32_t resolved = 0;
              for (uint32_t addr = start_addr; addr < end_addr; addr += 4) {
                uint32_t target = __builtin_bswap32(*reinterpret_cast<const uint32_t*>(base + addr));
                if (target != 0 && target != 0xFFFFFFFF) {
                  rex::runtime::ResolveIndirectFunction(target);
                  resolved++;
                }
              }
              return resolved;
            };

            uint32_t c_init = WarmupTable(0x82AA0000, 0x82AA000C);
            uint32_t c_pre = WarmupTable(0x82AB27A0, 0x82AB27AC);
            uint32_t cpp_init = WarmupTable(0x82AA0010, 0x82AB279C);
            REXLOG_INFO("[ios] Pre-resolved CRT initializer tables: C={}+{}, C++={}",
                        c_init, c_pre, cpp_init);
          }
        }
      }
    }
  }

  static void LogBuildIds() {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
      const char* path = _dyld_get_image_name(i);
      const char* name = path ? std::strrchr(path, '/') : nullptr;
      name = name ? name + 1 : path;
      if (!name || (std::strncmp(name, "librex", 6) != 0 &&
                    std::strcmp(name, "nfscarbon") != 0 &&
                    std::strcmp(name, "NFSCarbon") != 0)) {
        continue;
      }
      const auto* header = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(i));
      const auto* cmd = reinterpret_cast<const load_command*>(header + 1);
      for (uint32_t c = 0; c < header->ncmds; ++c) {
        if (cmd->cmd == LC_UUID) {
          const uint8_t* u = reinterpret_cast<const uuid_command*>(cmd)->uuid;
          REXLOG_INFO("[ios] build of {}: {:02X}{:02X}{:02X}{:02X}-{:02X}{:02X}-{:02X}{:02X}-"
                      "{:02X}{:02X}-{:02X}{:02X}{:02X}{:02X}{:02X}{:02X}",
                      name, u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10],
                      u[11], u[12], u[13], u[14], u[15]);
          break;
        }
        cmd = reinterpret_cast<const load_command*>(reinterpret_cast<const uint8_t*>(cmd) +
                                                    cmd->cmdsize);
      }
    }
  }

  void OnPostSetup() override {
    nfsmw::boot::Trace("game: runtime set up (OnPostSetup)");
    LogBuildIds();
    NfsCarbonApp::OnPostSetup();

    nfsmw::lifecycle::Install([] { if (nfsmw_ios_suspend_paints) nfsmw_ios_suspend_paints(true); },
                              [] { if (nfsmw_ios_suspend_paints) nfsmw_ios_suspend_paints(false); });

    nfsmw::achievements::Export(nfsmw::launcher::Documents());

    if (REXCVAR_GET(ios_touch_controls)) {
      nfsmw::touch::Install();
    }
    if (REXCVAR_GET(ios_show_fps)) {
      nfsmw::touch::InstallFpsCounter();
    }
    nfsmw::display::RequestRateForCap(REXCVAR_GET(ios_fps_cap));
    if (REXCVAR_GET(ios_gpu_capture)) {
      nfsmw::gpu_capture::InstallButton();
    }
  }

  void OnShutdown() override {
    NfsCarbonApp::OnShutdown();
  }
};

REX_DEFINE_APP(nfscarbon, IosNfsCarbonApp::Create)
