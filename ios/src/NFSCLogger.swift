//
//  NFSCLogger.swift
//  NFSCarbon
//
//  Production file-backed diagnostic logger writing concurrently to os_log/stdout
//  and <AppSandbox>/Documents/Logs/nfsc_runtime.log with log rotation, hardware specs,
//  and sandbox asset verification.
//

import Foundation
import os.log
import Metal
import UIKit

@objc public enum NFSCLogLevel: Int {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3
    case fatal = 4

    public var tagString: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO"
        case .warn:  return "WARN"
        case .error: return "ERROR"
        case .fatal: return "FATAL"
        }
    }
}

@objcMembers
public final class NFSCLogger: NSObject {
    public static let shared = NFSCLogger()

    private let logQueue = DispatchQueue(label: "com.antigravity.nfscarbon.logger", qos: .utility)
    private let dateFormatter: DateFormatter
    private let osLogger = Logger(subsystem: "com.antigravity.nfscarbon", category: "Engine")
    
    private var logFileHandle: FileHandle?
    private var logFilePath: URL
    private var logsDirectory: URL
    private let maxLogFileSizeBytes: UInt64 = 15 * 1024 * 1024 // 15 MB rotation limit

    public override init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.dateFormatter = formatter

        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logsDir = documentsURL.appendingPathComponent("Logs", isDirectory: true)
        self.logsDirectory = logsDir
        self.logFilePath = logsDir.appendingPathComponent("nfsc_runtime.log")

        super.init()

        setupLogDirectoryAndFile()
        rotateLogsIfNeeded()
    }

    // MARK: - Setup & Log File Rotation

    private func setupLogDirectoryAndFile() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: logsDirectory.path) {
            try? fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true, attributes: nil)
        }

        if !fileManager.fileExists(atPath: logFilePath.path) {
            fileManager.createFile(atPath: logFilePath.path, contents: nil, attributes: nil)
        }

        self.logFileHandle = FileHandle(forWritingAtPath: logFilePath.path)
        self.logFileHandle?.seekToEndOfFile()
    }

    private func rotateLogsIfNeeded() {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: logFilePath.path),
              let fileSize = attributes[.size] as? UInt64 else {
            return
        }

        if fileSize > maxLogFileSizeBytes {
            logFileHandle?.closeFile()
            logFileHandle = nil

            let prevLogPath = logsDirectory.appendingPathComponent("nfsc_runtime.prev.log")
            if fileManager.fileExists(atPath: prevLogPath.path) {
                try? fileManager.removeItem(at: prevLogPath)
            }
            try? fileManager.moveItem(at: logFilePath, to: prevLogPath)

            fileManager.createFile(atPath: logFilePath.path, contents: nil, attributes: nil)
            self.logFileHandle = FileHandle(forWritingAtPath: logFilePath.path)
            self.logFileHandle?.seekToEndOfFile()
            
            rawLog(level: .info, subsystem: "SYS", message: "Runtime log exceeded 15MB. Rotated to nfsc_runtime.prev.log.")
        }
    }

    // MARK: - Core Logging API

    public func log(level: NFSCLogLevel = .info, subsystem: String = "SYS", _ message: String) {
        rawLog(level: level, subsystem: subsystem, message: message)
    }

    public func info(_ subsystem: String = "SYS", _ message: String) {
        rawLog(level: .info, subsystem: subsystem, message: message)
    }

    public func warn(_ subsystem: String = "SYS", _ message: String) {
        rawLog(level: .warn, subsystem: subsystem, message: message)
    }

    public func error(_ subsystem: String = "SYS", _ message: String) {
        rawLog(level: .error, subsystem: subsystem, message: message)
    }

    public func debug(_ subsystem: String = "SYS", _ message: String) {
        rawLog(level: .debug, subsystem: subsystem, message: message)
    }

    public func fatal(_ subsystem: String = "CRASH", _ message: String) {
        rawLog(level: .fatal, subsystem: subsystem, message: message)
    }

    @objc(logWithTag:subsystem:message:)
    public func objcLog(tag: String, subsystem: String, message: String) {
        let level: NFSCLogLevel
        switch tag.uppercased() {
        case "DEBUG": level = .debug
        case "WARN", "WARNING": level = .warn
        case "ERROR": level = .error
        case "FATAL": level = .fatal
        default: level = .info
        }
        rawLog(level: level, subsystem: subsystem, message: message)
    }

    private func rawLog(level: NFSCLogLevel, subsystem: String, message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let formattedLine = "\(timestamp) [\(level.tagString)] [\(subsystem)] \(message)\n"

        // 1. Concurrent write to os_log / unified logging system
        switch level {
        case .debug:
            osLogger.debug("[\(subsystem)] \(message, privacy: .public)")
        case .info:
            osLogger.info("[\(subsystem)] \(message, privacy: .public)")
        case .warn:
            osLogger.warning("[\(subsystem)] \(message, privacy: .public)")
        case .error:
            osLogger.error("[\(subsystem)] \(message, privacy: .public)")
        case .fatal:
            osLogger.fault("[\(subsystem)] \(message, privacy: .public)")
        }

        // 2. Also print to stdout for IDE & LLDB console
        print(formattedLine, terminator: "")

        // 3. Thread-safe write to disk
        logQueue.async { [weak self] in
            guard let self = self, let data = formattedLine.data(using: .utf8) else { return }
            self.logFileHandle?.write(data)
        }
    }

    public func flush() {
        logQueue.sync {
            self.logFileHandle?.synchronizeFile()
        }
    }

    public func getLogFileContent() -> String? {
        flush()
        return try? String(contentsOf: logFilePath, encoding: .utf8)
    }

    public var activeLogPath: String {
        return logFilePath.path
    }

    public var crashLogPath: String {
        return logsDirectory.appendingPathComponent("crash.log").path
    }

    // MARK: - Startup Hardware & Environment Telemetry

    public func logStartupTelemetry() {
        rawLog(level: .info, subsystem: "SYS", message: "==========================================================")
        rawLog(level: .info, subsystem: "SYS", message: "   NEED FOR SPEED: CARBON (COLLECTOR'S EDITION) - iOS     ")
        rawLog(level: .info, subsystem: "SYS", message: "   Native Apple Silicon (ARM64) Static Recompilation Core  ")
        rawLog(level: .info, subsystem: "SYS", message: "==========================================================")

        // Device Model & OS
        let deviceModel = getHardwareModelIdentifier()
        let friendlyModel = getFriendlyDeviceModel(identifier: deviceModel)
        let osVersion = UIDevice.current.systemVersion
        let processorCount = ProcessInfo.processInfo.activeProcessorCount
        let physicalMemBytes = ProcessInfo.processInfo.physicalMemory
        let physicalMemMB = physicalMemBytes / (1024 * 1024)
        let physicalMemGB = Double(physicalMemBytes) / (1024.0 * 1024.0 * 1024.0)

        rawLog(level: .info, subsystem: "SYS", message: "Hardware: \(friendlyModel) (\(deviceModel))")
        rawLog(level: .info, subsystem: "SYS", message: "Operating System: iOS \(osVersion)")
        rawLog(level: .info, subsystem: "SYS", message: "CPU Core Count: \(processorCount) active physical/performance cores")
        rawLog(level: .info, subsystem: "SYS", message: String(format: "System RAM: %llu MB (%.2f GB physical)", physicalMemMB, physicalMemGB))

        // Metal GPU Device Query
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            let maxThreadsPerGroup = metalDevice.maxThreadsPerThreadgroup
            rawLog(level: .info, subsystem: "METAL", message: "GPU Device: \(metalDevice.name)")
            rawLog(level: .info, subsystem: "METAL", message: "Metal Tier: Apple Silicon GPU Family supported")
            rawLog(level: .info, subsystem: "METAL", message: "Max Threads Per Group: [\(maxThreadsPerGroup.width) x \(maxThreadsPerGroup.height) x \(maxThreadsPerGroup.depth)]")
            if #available(iOS 16.0, *) {
                rawLog(level: .info, subsystem: "METAL", message: "Metal 3 Support: \(metalDevice.supportsFamily(.metal3) ? "YES" : "NO")")
                rawLog(level: .info, subsystem: "METAL", message: "Apple 8 (A15/A16/M2) Family: \(metalDevice.supportsFamily(.apple8) ? "YES" : "NO")")
                if #available(iOS 17.0, *) {
                    rawLog(level: .info, subsystem: "METAL", message: "Apple 9 (A17/M3+) Family: \(metalDevice.supportsFamily(.apple9) ? "YES" : "NO")")
                }
            }
        } else {
            rawLog(level: .fatal, subsystem: "METAL", message: "CRITICAL: No Metal-capable GPU device found on this system!")
        }

        // Display Refresh Rate & ProMotion Check
        let maxFPS = UIScreen.main.maximumFramesPerSecond
        let isProMotion = maxFPS >= 120
        rawLog(level: .info, subsystem: "DISPLAY", message: "Display Maximum Refresh Rate: \(maxFPS) Hz")
        rawLog(level: .info, subsystem: "DISPLAY", message: "Apple ProMotion (120Hz) Capable: \(isProMotion ? "YES (Fluid 120 FPS Enabled)" : "NO (Targeting 60 FPS Locked)")")
        rawLog(level: .info, subsystem: "DISPLAY", message: "Display Bounds: \(Int(UIScreen.main.bounds.width))x\(Int(UIScreen.main.bounds.height)) @ \(Int(UIScreen.main.scale))x scale")
    }

    private func getHardwareModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier.isEmpty ? "Unknown" : identifier
    }

    private func getFriendlyDeviceModel(identifier: String) -> String {
        // Common lookup mappings for modern iPhones and iPads
        let map: [String: String] = [
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPad13,16": "iPad Air (5th gen)",
            "iPad13,17": "iPad Air (5th gen)",
            "iPad14,3":  "iPad Pro 11-inch (4th gen)",
            "iPad14,4":  "iPad Pro 11-inch (4th gen)",
            "iPad14,5":  "iPad Pro 12.9-inch (6th gen)",
            "iPad14,6":  "iPad Pro 12.9-inch (6th gen)",
            "iPad16,3":  "iPad Pro 11-inch (M4)",
            "iPad16,4":  "iPad Pro 11-inch (M4)",
            "iPad16,5":  "iPad Pro 13-inch (M4)",
            "iPad16,6":  "iPad Pro 13-inch (M4)"
        ]
        return map[identifier] ?? identifier
    }

    // MARK: - Game Asset Verification Subsystem

    public struct AssetVerificationReport {
        public let isComplete: Bool
        public let assetPath: String
        public let existingFilesCount: Int
        public let missingEssentials: [String]
        public let missingOptionals: [String]
    }

    public func verifyGameAssets() -> AssetVerificationReport {
        let fileManager = FileManager.default
        let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let nfscDir = documentsURL.appendingPathComponent("NFSC", isDirectory: true)

        rawLog(level: .info, subsystem: "FS", message: "Starting file integrity verification at: \(nfscDir.path)")

        if !fileManager.fileExists(atPath: nfscDir.path) {
            try? fileManager.createDirectory(at: nfscDir, withIntermediateDirectories: true, attributes: nil)
            rawLog(level: .warn, subsystem: "FS", message: "Created initial empty asset directory Documents/NFSC/")
        }

        // Essential binary and bundle archives required to boot
        let essentialRelativePaths = [
            "NFSC.exe",
            "GLOBAL/GLOBALB.LZC",
            "TRACKS/STREAML2R.BND"
        ]

        // Secondary data archives that provide complete Collector's Edition experiences
        let optionalRelativePaths = [
            "CARS/CARS.BND",
            "FRONTEND/FRONTEND.LZC",
            "FRONTEND/FRONTB.LZC",
            "SOUND/PFX.BND",
            "TRACKS/L2R.BND"
        ]

        var foundFileCount = 0
        if let enumerator = fileManager.enumerator(at: nfscDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if let isFile = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile {
                    foundFileCount += 1
                }
            }
        }

        rawLog(level: .info, subsystem: "FS", message: "Total regular files discovered in Documents/NFSC/: \(foundFileCount)")

        var missingEssentials: [String] = []
        for path in essentialRelativePaths {
            if !caseInsensitiveFileExists(baseDir: nfscDir, relativePath: path) {
                missingEssentials.append(path)
                rawLog(level: .error, subsystem: "FS", message: "[ERROR] MISSING CRITICAL FILE: Documents/NFSC/\(path)")
            } else {
                rawLog(level: .info, subsystem: "FS", message: "Verified critical file: Documents/NFSC/\(path)")
            }
        }

        var missingOptionals: [String] = []
        for path in optionalRelativePaths {
            if !caseInsensitiveFileExists(baseDir: nfscDir, relativePath: path) {
                missingOptionals.append(path)
                rawLog(level: .warn, subsystem: "FS", message: "[WARN] Missing secondary asset: Documents/NFSC/\(path)")
            }
        }

        let isComplete = missingEssentials.isEmpty
        if isComplete {
            rawLog(level: .info, subsystem: "FS", message: "Asset verification PASSED. All core executable archives and bundle maps present.")
        } else {
            rawLog(level: .error, subsystem: "FS", message: "Asset verification FAILED. \(missingEssentials.count) essential game files missing. Halting boot sequence.")
        }

        return AssetVerificationReport(
            isComplete: isComplete,
            assetPath: nfscDir.path,
            existingFilesCount: foundFileCount,
            missingEssentials: missingEssentials,
            missingOptionals: missingOptionals
        )
    }

    private func caseInsensitiveFileExists(baseDir: URL, relativePath: String) -> Bool {
        let components = relativePath.components(separatedBy: "/")
        var currentURL = baseDir
        let fileManager = FileManager.default

        for comp in components {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: currentURL.path) else {
                return false
            }
            if let matchedName = contents.first(where: { $0.caseInsensitiveCompare(comp) == .orderedSame }) {
                currentURL = currentURL.appendingPathComponent(matchedName)
            } else {
                return false
            }
        }
        return fileManager.fileExists(atPath: currentURL.path)
    }
}
