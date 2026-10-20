//
//  LoggerBridge.h
//  NFSCarbon
//
//  C/C++ bridging interface to NFSCLogger and Unix standard stream redirection.
//

#ifndef NFSC_LOGGER_BRIDGE_H
#define NFSC_LOGGER_BRIDGE_H

#include <stdarg.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Log an entry through the Swift NFSCLogger subsystem
void NFSCLog(const char* tag, const char* subsystem, const char* format, ...) __attribute__((format(printf, 3, 4)));

/// Specialized convenience loggers
void NFSCLogInfo(const char* subsystem, const char* format, ...) __attribute__((format(printf, 2, 3)));
void NFSCLogWarn(const char* subsystem, const char* format, ...) __attribute__((format(printf, 2, 3)));
void NFSCLogError(const char* subsystem, const char* format, ...) __attribute__((format(printf, 2, 3)));
void NFSCLogDebug(const char* subsystem, const char* format, ...) __attribute__((format(printf, 2, 3)));

/// Raw non-formatted message logging
void NFSCLogRaw(const char* tag, const char* subsystem, const char* message);

/// Flushes memory and file buffers of the active log sink
void NFSCLogFlush(void);

/// Captures native C/C++ printf/stdout/stderr and tees them into NFSCLogger
void NFSCRedirectStandardOutput(void);

/// Returns the filesystem path to the current runtime log file
const char* NFSCGetLogFilePath(void);

#ifdef __cplusplus
}
#endif

#endif // NFSC_LOGGER_BRIDGE_H
