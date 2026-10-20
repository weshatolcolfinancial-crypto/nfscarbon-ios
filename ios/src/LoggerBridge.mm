//
//  LoggerBridge.mm
//  NFSCarbon
//
//  Objective-C++ implementation of the logging bridge and stdout/stderr teeing pipe.
//

#import "LoggerBridge.h"
#import <Foundation/Foundation.h>
#import <os/log.h>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>

static int s_stdout_pipe[2] = {-1, -1};
static int s_stderr_pipe[2] = {-1, -1};
static pthread_t s_stdout_thread;
static pthread_t s_stderr_thread;
static NSString* s_logFilePath = nil;
static NSFileHandle* s_directFileHandle = nil;
static dispatch_queue_t s_bridgeQueue = nil;

static void EnsureDirectFileHandle() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_bridgeQueue = dispatch_queue_create("com.antigravity.nfscarbon.loggerbridge", DISPATCH_QUEUE_SERIAL);
        NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count > 0) {
            NSString* docs = paths[0];
            NSString* logsDir = [docs stringByAppendingPathComponent:@"Logs"];
            [[NSFileManager defaultManager] createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
            s_logFilePath = [logsDir stringByAppendingPathComponent:@"nfsc_runtime.log"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:s_logFilePath]) {
                [[NSFileManager defaultManager] createFileAtPath:s_logFilePath contents:nil attributes:nil];
            }
            s_directFileHandle = [NSFileHandle fileHandleForWritingAtPath:s_logFilePath];
            [s_directFileHandle seekToEndOfFile];
        }
    });
}

void NFSCLogRaw(const char* tag, const char* subsystem, const char* message) {
    if (!tag) tag = "INFO";
    if (!subsystem) subsystem = "SYS";
    if (!message) message = "";

    EnsureDirectFileHandle();

    // Call Swift NFSCLogger via selector if runtime has it registered
    Class swiftLoggerClass = NSClassFromString(@"NFSCarbon.NFSCLogger");
    if (!swiftLoggerClass) {
        swiftLoggerClass = NSClassFromString(@"NFSCLogger");
    }

    if (swiftLoggerClass) {
        id sharedLogger = [swiftLoggerClass valueForKey:@"shared"];
        if (sharedLogger) {
            SEL logSel = NSSelectorFromString(@"logWithTag:subsystem:message:");
            if ([sharedLogger respondsToSelector:logSel]) {
                NSString* nsTag = [NSString stringWithUTF8String:tag];
                NSString* nsSub = [NSString stringWithUTF8String:subsystem];
                NSString* nsMsg = [NSString stringWithUTF8String:message];
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [sharedLogger performSelector:logSel withObject:nsTag withObject:nsSub withObject:nsMsg];
                #pragma clang diagnostic pop
                return;
            }
        }
    }

    // Direct fallback write
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString* timestamp = [formatter stringFromDate:[NSDate date]];
    NSString* formattedLine = [NSString stringWithFormat:@"%@ [%s] [%s] %s\n", timestamp, tag, subsystem, message];

    // os_log
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[%{public}s] %{public}s", subsystem, message);
    fprintf(stdout, "%s", [formattedLine UTF8String]);

    if (s_bridgeQueue && s_directFileHandle) {
        dispatch_async(s_bridgeQueue, ^{
            NSData* data = [formattedLine dataUsingEncoding:NSUTF8StringEncoding];
            if (data) {
                [s_directFileHandle writeData:data];
            }
        });
    }
}

void NFSCLog(const char* tag, const char* subsystem, const char* format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NFSCLogRaw(tag, subsystem, buffer);
}

void NFSCLogInfo(const char* subsystem, const char* format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NFSCLogRaw("INFO", subsystem, buffer);
}

void NFSCLogWarn(const char* subsystem, const char* format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NFSCLogRaw("WARN", subsystem, buffer);
}

void NFSCLogError(const char* subsystem, const char* format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NFSCLogRaw("ERROR", subsystem, buffer);
}

void NFSCLogDebug(const char* subsystem, const char* format, ...) {
    va_list args;
    va_start(args, format);
    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NFSCLogRaw("DEBUG", subsystem, buffer);
}

void NFSCLogFlush(void) {
    if (s_bridgeQueue && s_directFileHandle) {
        dispatch_sync(s_bridgeQueue, ^{
            [s_directFileHandle synchronizeFile];
        });
    }
    fflush(stdout);
    fflush(stderr);
}

const char* NFSCGetLogFilePath(void) {
    EnsureDirectFileHandle();
    return [s_logFilePath UTF8String];
}

// MARK: - Stdout / Stderr Redirection Pipe

static void* PipeReaderThread(void* arg) {
    int readFd = (int)(intptr_t)arg;
    const char* subsystem = (readFd == s_stdout_pipe[0]) ? "STDOUT" : "STDERR";
    const char* tag = (readFd == s_stdout_pipe[0]) ? "INFO" : "ERROR";

    char lineBuffer[2048];
    size_t linePos = 0;
    char ch;

    while (read(readFd, &ch, 1) > 0) {
        if (ch == '\n' || linePos >= sizeof(lineBuffer) - 1) {
            lineBuffer[linePos] = '\0';
            if (linePos > 0) {
                NFSCLogRaw(tag, subsystem, lineBuffer);
            }
            linePos = 0;
        } else if (ch != '\r') {
            lineBuffer[linePos++] = ch;
        }
    }
    return NULL;
}

void NFSCRedirectStandardOutput(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        EnsureDirectFileHandle();

        // Redirect stdout
        if (pipe(s_stdout_pipe) == 0) {
            dup2(s_stdout_pipe[1], STDOUT_FILENO);
            close(s_stdout_pipe[1]);
            pthread_create(&s_stdout_thread, NULL, PipeReaderThread, (void*)(intptr_t)s_stdout_pipe[0]);
            pthread_detach(s_stdout_thread);
        }

        // Redirect stderr
        if (pipe(s_stderr_pipe) == 0) {
            dup2(s_stderr_pipe[1], STDERR_FILENO);
            close(s_stderr_pipe[1]);
            pthread_create(&s_stderr_thread, NULL, PipeReaderThread, (void*)(intptr_t)s_stderr_pipe[0]);
            pthread_detach(s_stderr_thread);
        }

        NFSCLogInfo("SYS", "Standard output and error streams redirected to NFSCLogger pipe.");
    });
}
