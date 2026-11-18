// Declarations for private macOS display APIs used by DisplayBar.
//
// CGVirtualDisplay* live in CoreGraphics (exported ObjC classes, used by Chromium's
// test harness and many virtual-display tools). MonitorPanel is reached only through
// the ObjC runtime (see CDisplayPrivate.m), so nothing here links a private framework.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic, nullable) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
@property (readonly, nonatomic) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings NS_SWIFT_NAME(apply(_:));
@end

/// Thin, failure-tolerant wrapper over the private MonitorPanel framework
/// (the engine behind System Settings › Displays): names, rotation, HDR and color presets.
/// Every method returns a neutral value when the framework or a selector is missing.
@interface DBMonitorPanel : NSObject
+ (BOOL)isAvailable NS_SWIFT_NAME(isAvailable());
+ (void)reload;
+ (nullable NSString *)titleForDisplay:(CGDirectDisplayID)display NS_SWIFT_NAME(title(for:));
+ (BOOL)canRotateDisplay:(CGDirectDisplayID)display NS_SWIFT_NAME(canRotate(_:));
+ (BOOL)setRotation:(int)degrees ofDisplay:(CGDirectDisplayID)display NS_SWIFT_NAME(setRotation(_:of:));
+ (BOOL)displayHasHDR:(CGDirectDisplayID)display NS_SWIFT_NAME(hasHDR(_:));
+ (BOOL)isHDREnabledOnDisplay:(CGDirectDisplayID)display NS_SWIFT_NAME(isHDREnabled(_:));
+ (BOOL)setHDREnabled:(BOOL)on onDisplay:(CGDirectDisplayID)display NS_SWIFT_NAME(setHDR(_:on:));
+ (NSArray<NSString *> *)presetNamesForDisplay:(CGDirectDisplayID)display NS_SWIFT_NAME(presetNames(_:));
+ (NSInteger)activePresetIndexForDisplay:(CGDirectDisplayID)display NS_SWIFT_NAME(activePresetIndex(_:));
+ (BOOL)setPresetAtIndex:(NSInteger)index forDisplay:(CGDirectDisplayID)display NS_SWIFT_NAME(setPreset(_:on:));
@end

NS_ASSUME_NONNULL_END
