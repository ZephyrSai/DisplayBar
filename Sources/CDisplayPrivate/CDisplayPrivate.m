#import "CDisplayPrivate.h"
#include <dlfcn.h>

// Selectors of MonitorPanel's MPDisplayMgr / MPDisplay / MPDisplayPreset, declared as
// protocols so messages to `id` resolve without colliding with public AppKit selectors.
@protocol DBMPDisplayMgr <NSObject>
- (NSArray *)displays;
@end

@protocol DBMPDisplayPreset <NSObject>
- (BOOL)isValid;
- (NSString *)presetName;
@end

@protocol DBMPDisplay <NSObject>
- (int)displayID;
- (NSString *)titleName;
- (BOOL)canChangeOrientation;
- (int)orientation;
- (void)setOrientation:(int)degrees;
- (BOOL)hasHDRModes;
- (BOOL)preferHDRModes;
- (void)setPreferHDRModes:(BOOL)on;
- (BOOL)hasPresets;
- (NSArray *)presets;
- (id)activePreset;
- (BOOL)setActivePreset:(id)preset;
@end

static id<DBMPDisplayMgr> gManager;

static id<DBMPDisplayMgr> DBManager(void) {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != NULL;
    });
    if (!loaded) return nil;
    if (!gManager) {
        Class cls = NSClassFromString(@"MPDisplayMgr");
        if (cls) gManager = (id<DBMPDisplayMgr>)[[cls alloc] init];
    }
    return gManager;
}

static id<DBMPDisplay> DBFind(CGDirectDisplayID display) {
    id<DBMPDisplayMgr> mgr = DBManager();
    if (![mgr respondsToSelector:@selector(displays)]) return nil;
    for (id<DBMPDisplay> d in [mgr displays]) {
        if ([d respondsToSelector:@selector(displayID)] && (CGDirectDisplayID)[d displayID] == display) return d;
    }
    return nil;
}

static NSArray *DBValidPresets(id<DBMPDisplay> d) {
    if (![d respondsToSelector:@selector(hasPresets)] || ![d hasPresets]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id<DBMPDisplayPreset> p in [d presets]) {
        if ([p respondsToSelector:@selector(isValid)] && [p isValid] && [p respondsToSelector:@selector(presetName)]) [out addObject:p];
    }
    return out;
}

@implementation DBMonitorPanel

+ (BOOL)isAvailable { return DBManager() != nil; }

+ (void)reload { gManager = nil; }

+ (NSString *)titleForDisplay:(CGDirectDisplayID)display {
    id<DBMPDisplay> d = DBFind(display);
    if (![d respondsToSelector:@selector(titleName)]) return nil;
    id name = [d titleName];
    return [name isKindOfClass:[NSString class]] ? name : nil;
}

+ (BOOL)canRotateDisplay:(CGDirectDisplayID)display {
    id<DBMPDisplay> d = DBFind(display);
    return [d respondsToSelector:@selector(canChangeOrientation)] && [d respondsToSelector:@selector(setOrientation:)] && [d canChangeOrientation];
}

+ (BOOL)setRotation:(int)degrees ofDisplay:(CGDirectDisplayID)display {
    id<DBMPDisplay> d = DBFind(display);
    if (![d respondsToSelector:@selector(setOrientation:)]) return NO;
    [d setOrientation:degrees];
    return YES;
}

+ (BOOL)displayHasHDR:(CGDirectDisplayID)display {
    id<DBMPDisplay> d = DBFind(display);
    return [d respondsToSelector:@selector(hasHDRModes)] && [d respondsToSelector:@selector(setPreferHDRModes:)] && [d hasHDRModes];
}

+ (BOOL)isHDREnabledOnDisplay:(CGDirectDisplayID)display {
    id<DBMPDisplay> d = DBFind(display);
    return [d respondsToSelector:@selector(preferHDRModes)] && [d preferHDRModes];
}

+ (BOOL)setHDREnabled:(BOOL)on onDisplay:(CGDirectDisplayID)display {
    id<DBMPDisplay> d = DBFind(display);
    if (![d respondsToSelector:@selector(setPreferHDRModes:)]) return NO;
    [d setPreferHDRModes:on];
    return YES;
}

+ (NSArray<NSString *> *)presetNamesForDisplay:(CGDirectDisplayID)display {
    NSMutableArray *names = [NSMutableArray array];
    for (id<DBMPDisplayPreset> p in DBValidPresets(DBFind(display))) {
        id name = [p presetName];
        [names addObject:[name isKindOfClass:[NSString class]] ? name : @"Preset"];
    }
    return names;
}

+ (NSInteger)activePresetIndexForDisplay:(CGDirectDisplayID)display {
    id<DBMPDisplay> d = DBFind(display);
    if (![d respondsToSelector:@selector(activePreset)]) return -1;
    NSArray *presets = DBValidPresets(d);
    id<DBMPDisplayPreset> active = [d activePreset];
    if (!active) return -1;
    NSUInteger idx = [presets indexOfObjectIdenticalTo:active];
    if (idx != NSNotFound) return (NSInteger)idx;
    if (![active respondsToSelector:@selector(presetName)]) return -1;
    for (NSUInteger i = 0; i < presets.count; i++) {
        if ([[presets[i] presetName] isEqual:[active presetName]]) return (NSInteger)i;
    }
    return -1;
}

+ (BOOL)setPresetAtIndex:(NSInteger)index forDisplay:(CGDirectDisplayID)display {
    id<DBMPDisplay> d = DBFind(display);
    NSArray *presets = DBValidPresets(d);
    if (index < 0 || index >= (NSInteger)presets.count || ![d respondsToSelector:@selector(setActivePreset:)]) return NO;
    return [d setActivePreset:presets[(NSUInteger)index]];
}

@end
