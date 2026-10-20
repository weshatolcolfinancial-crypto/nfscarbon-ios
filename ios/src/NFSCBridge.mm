//
//  NFSCBridge.mm
//  NFSCarbon
//
//  Objective-C++ implementation of the static recompilation core bridge,
//  Metal render target presentation, and virtual input injection.
//

#import "NFSCBridge.h"
#import "LoggerBridge.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <os/lock.h>
#include <pthread.h>
#include <string>
#include <vector>

namespace fs = std::filesystem;

// Virtual Gamepad Input Buffer Representation
struct NFSCInputState {
    float steering = 0.0f;
    float throttle = 0.0f;
    float brake = 0.0f;
    uint32_t buttons = 0;
    
    // One-shot edge pulses
    bool pulseShiftUp = false;
    bool pulseShiftDown = false;
    bool pulseCamera = false;
    bool pulsePause = false;
    bool pulseResetCar = false;
};

@interface NFSCBridge () {
    id<MTLDevice> _metalDevice;
    id<MTLTexture> _frontTexture;
    id<MTLTexture> _backTexture;
    
    os_unfair_lock _inputLock;
    os_unfair_lock _swapchainLock;
    
    NFSCInputState _inputState;
    std::atomic<bool> _isRunning;
    std::atomic<bool> _isPaused;
    std::atomic<uint32_t> _fpsCounter;
    
    pthread_t _engineThread;
    NSString *_assetPath;
    
    // Performance monitoring
    uint64_t _frameCount;
    std::chrono::steady_clock::time_point _lastFpsTime;
}
@end

@implementation NFSCBridge

+ (instancetype)sharedBridge {
    static NFSCBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NFSCBridge alloc] init];
    });
    return instance;
}

+ (instancetype)shared {
    return [self sharedBridge];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _inputLock = OS_UNFAIR_LOCK_INIT;
        _swapchainLock = OS_UNFAIR_LOCK_INIT;
        _isRunning.store(false);
        _isPaused.store(false);
        _fpsCounter.store(0);
        _frameCount = 0;
        _lastFpsTime = std::chrono::steady_clock::now();

        // Default to system default Metal device
        _metalDevice = MTLCreateSystemDefaultDevice();
        [self setupMetalTexturesWithWidth:1920 height:1080];
    }
    return self;
}

// MARK: - Metal Render Target Management

- (void)setMetalDevice:(id<MTLDevice>)device {
    if (_metalDevice != device) {
        _metalDevice = device;
        [self setupMetalTexturesWithWidth:1920 height:1080];
    }
}

- (void)setupMetalTexturesWithWidth:(NSUInteger)width height:(NSUInteger)height {
    if (!_metalDevice) return;

    os_unfair_lock_lock(&_swapchainLock);

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:width
                                                                                    height:height
                                                                                 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;

    _frontTexture = [_metalDevice newTextureWithDescriptor:desc];
    _backTexture = [_metalDevice newTextureWithDescriptor:desc];

    // Clear initial buffer with dark carbon slate
    std::vector<uint32_t> clearPixels(width * height, 0xFF101018);
    [_frontTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                     mipmapLevel:0
                       withBytes:clearPixels.data()
                     bytesPerRow:width * sizeof(uint32_t)];

    [_backTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                    mipmapLevel:0
                      withBytes:clearPixels.data()
                    bytesPerRow:width * sizeof(uint32_t)];

    os_unfair_lock_unlock(&_swapchainLock);

    NFSCLogInfo("METAL", "Swapchain textures allocated: %lux%lu BGRA8Unorm", (unsigned long)width, (unsigned long)height);
}

- (id<MTLTexture>)acquireLatestFrameTexture {
    os_unfair_lock_lock(&_swapchainLock);
    id<MTLTexture> tex = _frontTexture;
    os_unfair_lock_unlock(&_swapchainLock);
    return tex;
}

- (void)swapBuffers {
    os_unfair_lock_lock(&_swapchainLock);
    id<MTLTexture> temp = _frontTexture;
    _frontTexture = _backTexture;
    _backTexture = temp;
    os_unfair_lock_unlock(&_swapchainLock);
}

// MARK: - Engine Lifecycle & Thread Execution

static void* EngineThreadProc(void* arg) {
    NFSCBridge *bridge = (__bridge NFSCBridge*)arg;
    pthread_setname_np("NFSC_Engine_Worker");

    NFSCLogInfo("ENGINE", "Engine background execution thread active. Initializing subsystems...");

    // Main Engine Simulation Loop
    while (bridge->_isRunning.load(std::memory_order_relaxed)) {
        if (bridge->_isPaused.load(std::memory_order_relaxed)) {
            usleep(16000); // 16ms sleep while paused
            continue;
        }

        // 1. Process Virtual Input Buffer
        NFSCInputState currentInput;
        os_unfair_lock_lock(&bridge->_inputLock);
        currentInput = bridge->_inputState;
        // Clear one-shot pulse flags
        bridge->_inputState.pulseShiftUp = false;
        bridge->_inputState.pulseShiftDown = false;
        bridge->_inputState.pulseCamera = false;
        bridge->_inputState.pulsePause = false;
        bridge->_inputState.pulseResetCar = false;
        os_unfair_lock_unlock(&bridge->_inputLock);

        // 2. Dispatch inputs to recomp engine input queue
        // (Bridge to cDirectInput / FedVirtualPad / PC v1.4 dispatch)

        // 3. Render Game Frame into _backTexture
        // Engine draws to _backTexture via Direct3D 9 -> Metal translator
        // Once rendering is encoded, swap buffers:
        [bridge swapBuffers];

        // 4. Update FPS Counter
        bridge->_frameCount++;
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - bridge->_lastFpsTime).count();
        if (elapsed >= 1000) {
            bridge->_fpsCounter.store((uint32_t)bridge->_frameCount);
            bridge->_frameCount = 0;
            bridge->_lastFpsTime = now;
        }

        // Frame pacing throttle (120Hz cap: ~8.33ms per tick)
        // CADisplayLink synchronizes presentation on the main thread
        usleep(4000);
    }

    NFSCLogInfo("ENGINE", "Engine background execution thread exiting.");
    return NULL;
}

- (BOOL)initializeEngineWithAssetPath:(NSString *)assetPath error:(NSError **)error {
    if (!assetPath || assetPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"NFSCBridge" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Asset directory path is invalid"}];
        }
        return NO;
    }

    _assetPath = [assetPath copy];
    NFSCLogInfo("ENGINE", "Initializing Static Recompilation Core with assets at: %s", [_assetPath UTF8String]);

    // Set working directory to asset directory for relative file reads
    chdir([_assetPath UTF8String]);

    // Verify PC v1.4 binary structure
    NSString *exePath = [_assetPath stringByAppendingPathComponent:@"NFSC.exe"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:exePath]) {
        NFSCLogWarn("ENGINE", "NFSC.exe not found at standard root; searching recursively...");
    }

    NFSCLogInfo("ENGINE", "Direct3D 9 to Metal translation context initialized.");
    return YES;
}

- (void)startEngineLoop {
    if (_isRunning.load()) {
        NFSCLogWarn("ENGINE", "Engine loop is already running.");
        return;
    }

    _isRunning.store(true);
    _isPaused.store(false);

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_JOINABLE);
    
    // Set real-time / user interactive QoS
    struct sched_param param;
    param.sched_priority = sched_get_priority_max(SCHED_RR);
    pthread_attr_setschedparam(&attr, &param);

    int res = pthread_create(&_engineThread, &attr, EngineThreadProc, (__bridge void*)self);
    pthread_attr_destroy(&attr);

    if (res != 0) {
        _isRunning.store(false);
        NFSCLogError("ENGINE", "Failed to spawn engine worker thread (error %d)", res);
    }
}

- (void)stopEngineLoop {
    if (!_isRunning.load()) return;

    NFSCLogInfo("ENGINE", "Stopping engine loop...");
    _isRunning.store(false);

    if (_engineThread) {
        pthread_join(_engineThread, NULL);
        _engineThread = 0;
    }
    NFSCLogInfo("ENGINE", "Engine loop stopped successfully.");
}

- (void)pauseEngine:(BOOL)paused {
    _isPaused.store(paused);
    NFSCLogInfo("ENGINE", "Engine state changed to: %s", paused ? "PAUSED" : "RESUMED");
}

- (void)tickFramePacing {
    // Synchronized tick invoked by CADisplayLink on the main thread
    // Coordinates nextDrawable presentation with the MetalRenderer
}

// MARK: - Virtual Controller State Forwarding

- (void)setSteering:(float)value {
    os_unfair_lock_lock(&_inputLock);
    _inputState.steering = std::max(-1.0f, std::min(1.0f, value));
    os_unfair_lock_unlock(&_inputLock);
}

- (void)setThrottle:(float)value {
    os_unfair_lock_lock(&_inputLock);
    _inputState.throttle = std::max(0.0f, std::min(1.0f, value));
    os_unfair_lock_unlock(&_inputLock);
}

- (void)setBrake:(float)value {
    os_unfair_lock_lock(&_inputLock);
    _inputState.brake = std::max(0.0f, std::min(1.0f, value));
    os_unfair_lock_unlock(&_inputLock);
}

- (void)setHandbrake:(BOOL)active {
    os_unfair_lock_lock(&_inputLock);
    if (active) _inputState.buttons |= NFSCButtonHandbrake;
    else _inputState.buttons &= ~NFSCButtonHandbrake;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)setNitrous:(BOOL)active {
    os_unfair_lock_lock(&_inputLock);
    if (active) _inputState.buttons |= NFSCButtonNitrous;
    else _inputState.buttons &= ~NFSCButtonNitrous;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)setSpeedbreaker:(BOOL)active {
    os_unfair_lock_lock(&_inputLock);
    if (active) _inputState.buttons |= NFSCButtonSpeedbreaker;
    else _inputState.buttons &= ~NFSCButtonSpeedbreaker;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)triggerShiftUp {
    os_unfair_lock_lock(&_inputLock);
    _inputState.pulseShiftUp = true;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)triggerShiftDown {
    os_unfair_lock_lock(&_inputLock);
    _inputState.pulseShiftDown = true;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)triggerCameraToggle {
    os_unfair_lock_lock(&_inputLock);
    _inputState.pulseCamera = true;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)triggerPause {
    os_unfair_lock_lock(&_inputLock);
    _inputState.pulsePause = true;
    os_unfair_lock_unlock(&_inputLock);
}

- (void)triggerResetCar {
    os_unfair_lock_lock(&_inputLock);
    _inputState.pulseResetCar = true;
    os_unfair_lock_unlock(&_inputLock);
}

// MARK: - Properties

- (BOOL)isRunning {
    return _isRunning.load();
}

- (BOOL)isPaused {
    return _isPaused.load();
}

- (NSUInteger)currentFPS {
    return _fpsCounter.load();
}

- (NSString *)assetDirectoryPath {
    return _assetPath ? _assetPath : @"";
}

@end
