//
//  CrashReporter.h
//  NFSCarbon
//
//  Unix signal crash handler and NSUncaughtExceptionHandler with synchronous
//  stack trace dumping to Documents/Logs/crash.log.
//

#ifndef NFSC_CRASH_REPORTER_H
#define NFSC_CRASH_REPORTER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Installs signal handlers (SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE)
/// and NSSetUncaughtExceptionHandler.
void NFSCInstallCrashReporter(void);

/// Uninstalls crash handlers and restores system defaults.
void NFSCUninstallCrashReporter(void);

/// Forces a test crash or simulated dump (for diagnostic verification)
void NFSCSimulateCrashDump(const char* reason);

#ifdef __cplusplus
}
#endif

#endif // NFSC_CRASH_REPORTER_H
