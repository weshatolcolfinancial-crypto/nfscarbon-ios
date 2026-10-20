//
//  CrashReporter.mm
//  NFSCarbon
//
//  Low-level, async-signal-safe crash reporter writing to Documents/Logs/crash.log.
//

#import "CrashReporter.h"
#import "LoggerBridge.h"
#import <Foundation/Foundation.h>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <execinfo.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static char s_crashLogPath[1024] = {0};
static char s_runtimeLogPath[1024] = {0};
static struct sigaction s_old_sa[NSIG];
static stack_t s_altStack;
static void* s_altStackMemory = nullptr;
static const size_t kAltStackSize = 64 * 1024; // 64 KB dedicated stack

static const int kObservedSignals[] = {
    SIGSEGV,
    SIGBUS,
    SIGABRT,
    SIGILL,
    SIGFPE,
    SIGPIPE
};
static const size_t kObservedSignalsCount = sizeof(kObservedSignals) / sizeof(kObservedSignals[0]);

// Simple async-signal-safe string writer
static void SafeWrite(int fd, const char* str) {
    if (!str || fd < 0) return;
    write(fd, str, strlen(str));
}

static void SafeWriteUInt64(int fd, uint64_t val) {
    char buf[32];
    int pos = 0;
    if (val == 0) {
        SafeWrite(fd, "0");
        return;
    }
    char temp[32];
    int tpos = 0;
    while (val > 0) {
        temp[tpos++] = '0' + (val % 10);
        val /= 10;
    }
    while (tpos > 0) {
        buf[pos++] = temp[--tpos];
    }
    buf[pos] = '\0';
    SafeWrite(fd, buf);
}

static void SafeWriteHex(int fd, uintptr_t val) {
    SafeWrite(fd, "0x");
    char hexDigits[] = "0123456789ABCDEF";
    char temp[32];
    int tpos = 0;
    if (val == 0) {
        SafeWrite(fd, "0");
        return;
    }
    while (val > 0) {
        temp[tpos++] = hexDigits[val & 0xF];
        val >>= 4;
    }
    char buf[32];
    int pos = 0;
    while (tpos > 0) {
        buf[pos++] = temp[--tpos];
    }
    buf[pos] = '\0';
    SafeWrite(fd, buf);
}

static const char* GetSignalName(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV (Segmentation Fault / Invalid Memory Reference)";
        case SIGBUS:  return "SIGBUS (Bus Error / Misaligned Access)";
        case SIGABRT: return "SIGABRT (Abort / Assertion Failure)";
        case SIGILL:  return "SIGILL (Illegal Instruction)";
        case SIGFPE:  return "SIGFPE (Floating Point Exception)";
        case SIGPIPE: return "SIGPIPE (Broken Pipe)";
        default:      return "UNKNOWN SIGNAL";
    }
}

static void SignalHandler(int sig, siginfo_t* info, void* ucontext) {
    // Open crash.log directly with low-level POSIX call (async-signal-safe)
    int fd = open(s_crashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) {
        // Fallback to stderr
        fd = STDERR_FILENO;
    }

    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char timeStr[64];
    strftime(timeStr, sizeof(timeStr), "%Y-%m-%d %H:%M:%S", &tm_buf);

    SafeWrite(fd, "\n======================================================================\n");
    SafeWrite(fd, "              NFS CARBON iOS - CRITICAL CRASH REPORT                  \n");
    SafeWrite(fd, "======================================================================\n");
    SafeWrite(fd, "Crash Timestamp: ");
    SafeWrite(fd, timeStr);
    SafeWrite(fd, "\nSignal: ");
    SafeWriteUInt64(fd, (uint64_t)sig);
    SafeWrite(fd, " -> ");
    SafeWrite(fd, GetSignalName(sig));
    SafeWrite(fd, "\nFault Address: ");
    if (info) {
        SafeWriteHex(fd, (uintptr_t)info->si_addr);
        SafeWrite(fd, " (si_code: ");
        SafeWriteUInt64(fd, (uint64_t)info->si_code);
        SafeWrite(fd, ")");
    } else {
        SafeWrite(fd, "N/A");
    }
    SafeWrite(fd, "\nProcess ID: ");
    SafeWriteUInt64(fd, (uint64_t)getpid());
    SafeWrite(fd, " | Thread: ");
    SafeWriteHex(fd, (uintptr_t)pthread_self());

    // Task Memory Information via Mach API
    mach_task_basic_info_data_t taskInfo;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&taskInfo, &count) == KERN_SUCCESS) {
        SafeWrite(fd, "\nResident Memory: ");
        SafeWriteUInt64(fd, taskInfo.resident_size / (1024 * 1024));
        SafeWrite(fd, " MB | Virtual Memory: ");
        SafeWriteUInt64(fd, taskInfo.virtual_size / (1024 * 1024));
        SafeWrite(fd, " MB");
    }

    SafeWrite(fd, "\n\n------------- BACKTRACE CALLSTACK -------------\n");
    void* callstack[128];
    int frames = backtrace(callstack, 128);
    backtrace_symbols_fd(callstack, frames, fd);

    SafeWrite(fd, "------------------------------------------------\n");
    SafeWrite(fd, "End of crash diagnostics. Terminating process.\n");
    SafeWrite(fd, "======================================================================\n\n");

    fsync(fd);
    if (fd != STDERR_FILENO) {
        close(fd);
    }

    // Flush any pending NFSCLog writes
    NFSCLogFlush();

    // Reset signal handler to default and re-raise so system registers abort
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, nullptr);

    kill(getpid(), sig);
}

static void UncaughtExceptionHandler(NSException* exception) {
    if (!exception) return;

    int fd = open(s_crashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) fd = STDERR_FILENO;

    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    char timeStr[64];
    strftime(timeStr, sizeof(timeStr), "%Y-%m-%d %H:%M:%S", &tm_buf);

    SafeWrite(fd, "\n======================================================================\n");
    SafeWrite(fd, "       NFS CARBON iOS - UNCAUGHT OBJECTIVE-C/SWIFT EXCEPTION          \n");
    SafeWrite(fd, "======================================================================\n");
    SafeWrite(fd, "Timestamp: ");
    SafeWrite(fd, timeStr);
    SafeWrite(fd, "\nName: ");
    SafeWrite(fd, [[exception name] UTF8String]);
    SafeWrite(fd, "\nReason: ");
    SafeWrite(fd, [[exception reason] UTF8String]);
    SafeWrite(fd, "\n\nCallstack:\n");

    NSArray<NSString*>* symbols = [exception callStackSymbols];
    for (NSString* sym in symbols) {
        SafeWrite(fd, [sym UTF8String]);
        SafeWrite(fd, "\n");
    }
    SafeWrite(fd, "======================================================================\n\n");

    fsync(fd);
    if (fd != STDERR_FILENO) close(fd);

    NFSCLogError("CRASH", "Uncaught Exception: %s - Reason: %s", [[exception name] UTF8String], [[exception reason] UTF8String]);
    NFSCLogFlush();
}

void NFSCInstallCrashReporter(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Prepare file paths
        NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            NSString* logsDir = [paths[0] stringByAppendingPathComponent:@"Logs"];
            [[NSFileManager defaultManager] createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString* crashPath = [logsDir stringByAppendingPathComponent:@"crash.log"];
            NSString* runtimePath = [logsDir stringByAppendingPathComponent:@"nfsc_runtime.log"];
            strncpy(s_crashLogPath, [crashPath UTF8String], sizeof(s_crashLogPath) - 1);
            strncpy(s_runtimeLogPath, [runtimePath UTF8String], sizeof(s_runtimeLogPath) - 1);
        }

        // Setup alternate signal stack
        s_altStackMemory = malloc(kAltStackSize);
        if (s_altStackMemory) {
            s_altStack.ss_sp = s_altStackMemory;
            s_altStack.ss_size = kAltStackSize;
            s_altStack.ss_flags = 0;
            if (sigaltstack(&s_altStack, nullptr) != 0) {
                NFSCLogWarn("SYS", "Could not allocate alternate signal stack.");
            }
        }

        // Install Unix signal handlers
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = SignalHandler;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&sa.sa_mask);

        for (size_t i = 0; i < kObservedSignalsCount; ++i) {
            int sig = kObservedSignals[i];
            sigaction(sig, &sa, &s_old_sa[sig]);
        }

        // Install NSUncaughtExceptionHandler
        NSSetUncaughtExceptionHandler(&UncaughtExceptionHandler);

        NFSCLogInfo("SYS", "Signal crash handlers (SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE, SIGPIPE) installed successfully.");
    });
}

void NFSCUninstallCrashReporter(void) {
    for (size_t i = 0; i < kObservedSignalsCount; ++i) {
        int sig = kObservedSignals[i];
        sigaction(sig, &s_old_sa[sig], nullptr);
    }
    NSSetUncaughtExceptionHandler(nullptr);
    if (s_altStackMemory) {
        stack_t disableStack;
        disableStack.ss_flags = SS_DISABLE;
        sigaltstack(&disableStack, nullptr);
        free(s_altStackMemory);
        s_altStackMemory = nullptr;
    }
}

void NFSCSimulateCrashDump(const char* reason) {
    NFSCLogWarn("CRASH", "Simulating diagnostic crash dump for verification: %s", reason ? reason : "Manual trigger");
    int fd = open(s_crashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd >= 0) {
        SafeWrite(fd, "\n[SIMULATED CRASH DUMP TEST: ");
        SafeWrite(fd, reason ? reason : "Manual trigger");
        SafeWrite(fd, "]\n");
        void* callstack[64];
        int frames = backtrace(callstack, 64);
        backtrace_symbols_fd(callstack, frames, fd);
        SafeWrite(fd, "[END SIMULATION]\n");
        fsync(fd);
        close(fd);
    }
}
