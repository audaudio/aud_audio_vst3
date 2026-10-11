// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The editor's end of the surface channel (ticket 24, variants A and S; see
// src/aud_vst3_mach.h of aud_audio_vst3), one per Flutter view: finds the
// IOSurface-backed layer of the view, copies every frame Flutter commits
// into a pool of three IOSurfaces it shares with the plugin, and tells the
// plugin which surface holds which frame. The copy runs off the main
// thread, which is Flutter's platform and UI thread. All bridges of the
// process share one Mach connection to the plugin.
@interface AudEditorBridge : NSObject

// Connects the view of plugin instance `instance` to the plugin's port
// registered under `serviceName`; NULL when the plugin is gone.
- (nullable instancetype)initWithServiceName:(NSString*)serviceName
                                 contentView:(NSView*)contentView
                                    instance:(uint32_t)instance;

// Frames are not sent while paused - a warm view whose plugin view is
// closed. Resuming sends the current frame.
@property(nonatomic) BOOL paused;

// The frames copied, and those dropped because no surface was free.
@property(nonatomic, readonly) uint64_t framesSent;
@property(nonatomic, readonly) uint64_t framesDropped;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
