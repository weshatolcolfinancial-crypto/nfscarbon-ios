//
//  NFSCBridge.h
//  NFSCarbon
//
//  Objective-C++ bridge wrapping the static recompilation core, Direct3D 9 to
//  Metal translation pipeline, and virtual input injection.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

// Virtual Gamepad Button Bitmask
typedef NS_OPTIONS(NSUInteger, NFSCButtonMask) {
    NFSCButtonNone          = 0,
    NFSCButtonHandbrake     = 1 << 0,
    NFSCButtonNitrous       = 1 << 1,
    NFSCButtonSpeedbreaker  = 1 << 2,
    NFSCButtonShiftUp       = 1 << 3,
    NFSCButtonShiftDown     = 1 << 4,
    NFSCButtonCamera        = 1 << 5,
    NFSCButtonPause         = 1 << 6,
    NFSCButtonResetCar      = 1 << 7,
    NFSCButtonLookBack      = 1 << 8
};

@interface NFSCBridge : NSObject

/// Shared singleton instance
+ (instancetype)sharedBridge;
+ (instancetype)shared;

/// Engine Lifecycle
- (BOOL)initializeEngineWithAssetPath:(NSString *)assetPath error:(NSError **)error;
- (void)startEngineLoop;
- (void)stopEngineLoop;
- (void)pauseEngine:(BOOL)paused;
- (void)tickFramePacing;

/// Metal Swapchain & Presentation
- (void)setMetalDevice:(id<MTLDevice>)device;
- (nullable id<MTLTexture>)acquireLatestFrameTexture;

/// Virtual Controller State Forwarding
- (void)setSteering:(float)value;    // -1.0 (full left) to +1.0 (full right)
- (void)setThrottle:(float)value;    //  0.0 to 1.0
- (void)setBrake:(float)value;       //  0.0 to 1.0
- (void)setHandbrake:(BOOL)active;
- (void)setNitrous:(BOOL)active;
- (void)setSpeedbreaker:(BOOL)active;
- (void)triggerShiftUp;
- (void)triggerShiftDown;
- (void)triggerCameraToggle;
- (void)triggerPause;
- (void)triggerResetCar;

/// Query Engine Status
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
@property (nonatomic, readonly) NSUInteger currentFPS;
@property (nonatomic, readonly) NSString *assetDirectoryPath;

@end

NS_ASSUME_NONNULL_END
