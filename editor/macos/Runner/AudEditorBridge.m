// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

#import "AudEditorBridge.h"

#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#include <bootstrap.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <servers/bootstrap.h>
#include <string.h>
#include <unistd.h>

#include "../../../src/aud_vst3_mach.h"

static int64_t AudNowNs(void) {
  static mach_timebase_info_data_t info;
  if (info.denom == 0) mach_timebase_info(&info);
  return (int64_t)(mach_absolute_time() * info.numer / info.denom);
}

static void* const kContentsContext = (void*)&kContentsContext;

@interface AudEditorBridge ()
- (void)releaseIndex:(uint32_t)index generation:(uint32_t)generation;
@end

// The process's Mach connection to the plugin: the plugin's port, the
// editor's own port for AUD_MACH_RELEASE, and the bridges by instance.
@interface AudEditorChannel : NSObject
@property(nonatomic, readonly) mach_port_t pluginPort;
@property(nonatomic, readonly) dispatch_queue_t queue;
+ (nullable instancetype)channelForService:(NSString*)serviceName;
- (void)addBridge:(AudEditorBridge*)bridge instance:(uint32_t)instance;
- (void)removeInstance:(uint32_t)instance;
@end

@implementation AudEditorChannel {
  mach_port_t _ownPort;
  dispatch_source_t _receive;
  NSMapTable<NSNumber*, AudEditorBridge*>* _bridges;
  NSLock* _lock;
}

+ (nullable instancetype)channelForService:(NSString*)serviceName {
  static AudEditorChannel* channel;
  static NSString* service;
  if (channel != nil && [service isEqualToString:serviceName]) return channel;
  mach_port_t pluginPort = MACH_PORT_NULL;
  if (bootstrap_look_up(bootstrap_port, serviceName.UTF8String, &pluginPort) !=
      KERN_SUCCESS) {
    return nil;
  }
  channel = [[AudEditorChannel alloc] initWithPluginPort:pluginPort];
  service = [serviceName copy];
  return channel;
}

- (instancetype)initWithPluginPort:(mach_port_t)pluginPort {
  self = [super init];
  if (self == nil) return nil;
  _pluginPort = pluginPort;
  _lock = [NSLock new];
  _bridges = [NSMapTable strongToWeakObjectsMapTable];
  _queue = dispatch_queue_create("aud.editor.copy", DISPATCH_QUEUE_SERIAL);
  mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &_ownPort);
  mach_port_insert_right(mach_task_self(), _ownPort, _ownPort,
                         MACH_MSG_TYPE_MAKE_SEND);
  // Room for the releases of every view of the process: the default queue
  // holds 5, and the plugin never waits for a full one.
  mach_port_limits_t limits = {.mpl_qlimit = 64};
  mach_port_set_attributes(mach_task_self(), _ownPort, MACH_PORT_LIMITS_INFO,
                           (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
  AudMachHello hello;
  memset(&hello, 0, sizeof(hello));
  hello.header.msgh_bits =
      MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
  hello.header.msgh_size = sizeof(hello);
  hello.header.msgh_remote_port = _pluginPort;
  hello.header.msgh_id = AUD_MACH_HELLO;
  hello.body.msgh_descriptor_count = 1;
  hello.port.name = _ownPort;
  hello.port.disposition = MACH_MSG_TYPE_MAKE_SEND;
  hello.port.type = MACH_MSG_PORT_DESCRIPTOR;
  hello.pid = getpid();
  mach_msg(&hello.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(hello), 0,
           MACH_PORT_NULL, 100, MACH_PORT_NULL);
  mach_port_t port = _ownPort;
  __weak AudEditorChannel* weakSelf = self;
  _receive = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, _ownPort, 0, _queue);
  dispatch_source_set_event_handler(_receive, ^{
    AudMachBuffer buffer;
    memset(&buffer, 0, sizeof(buffer));
    if (mach_msg(&buffer.release.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0,
                 sizeof(buffer), port, 0, MACH_PORT_NULL) != KERN_SUCCESS) {
      return;
    }
    if (buffer.release.header.msgh_id == AUD_MACH_RELEASE) {
      [[weakSelf bridgeFor:buffer.release.instance]
          releaseIndex:buffer.release.index
            generation:buffer.release.generation];
    }
    mach_msg_destroy(&buffer.release.header);
  });
  dispatch_resume(_receive);
  return self;
}

- (nullable AudEditorBridge*)bridgeFor:(uint32_t)instance {
  [_lock lock];
  AudEditorBridge* bridge = [_bridges objectForKey:@(instance)];
  [_lock unlock];
  return bridge;
}

- (void)addBridge:(AudEditorBridge*)bridge instance:(uint32_t)instance {
  [_lock lock];
  [_bridges setObject:bridge forKey:@(instance)];
  [_lock unlock];
}

- (void)removeInstance:(uint32_t)instance {
  [_lock lock];
  [_bridges removeObjectForKey:@(instance)];
  [_lock unlock];
}

@end

@implementation AudEditorBridge {
  AudEditorChannel* _channel;
  NSView* _contentView;
  CALayer* _observed;
  NSTimer* _scan;
  uint32_t _instance;
  IOSurfaceRef _pool[AUD_MACH_POOL_SIZE];
  // Written on the main thread, released on the channel's queue: guarded.
  BOOL _free[AUD_MACH_POOL_SIZE];
  uint32_t _generation;
  uint32_t _next;
  uint64_t _frame;
  // A frame was dropped for want of a free surface: the next release
  // captures the current contents, which Flutter will not draw again.
  BOOL _recapture;
  NSLock* _lock;
}

- (nullable instancetype)initWithServiceName:(NSString*)serviceName
                                 contentView:(NSView*)contentView
                                    instance:(uint32_t)instance {
  self = [super init];
  if (self == nil) return nil;
  _channel = [AudEditorChannel channelForService:serviceName];
  if (_channel == nil) return nil;
  _contentView = contentView;
  _instance = instance;
  _lock = [NSLock new];
  [_channel addBridge:self instance:instance];
  __weak AudEditorBridge* weakSelf = self;
  _scan = [NSTimer scheduledTimerWithTimeInterval:0.1
                                          repeats:YES
                                            block:^(NSTimer* timer) {
                                              [weakSelf observeSurfaceLayer];
                                            }];
  [self observeSurfaceLayer];
  return self;
}

- (void)dealloc {
  [self stop];
}

- (void)stop {
  [_scan invalidate];
  _scan = nil;
  [_channel removeInstance:_instance];
  if (_observed != nil) {
    [_observed removeObserver:self forKeyPath:@"contents" context:kContentsContext];
    _observed = nil;
  }
  [_lock lock];
  for (int i = 0; i < AUD_MACH_POOL_SIZE; ++i) {
    if (_pool[i] != NULL) CFRelease(_pool[i]);
    _pool[i] = NULL;
  }
  [_lock unlock];
}

// Shown again: the view needs the current frame, which Flutter will not
// draw again while nothing changes.
- (void)setPaused:(BOOL)paused {
  const BOOL resumed = _paused && !paused;
  _paused = paused;
  if (resumed) [self captureCurrent];
}

- (void)releaseIndex:(uint32_t)index generation:(uint32_t)generation {
  [_lock lock];
  if (generation == _generation && index < AUD_MACH_POOL_SIZE) _free[index] = YES;
  const BOOL recapture = _recapture;
  _recapture = NO;
  [_lock unlock];
  if (!recapture) return;
  __weak AudEditorBridge* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf captureCurrent];
  });
}

// The surface the FlutterView shows now, sent again.
- (void)captureCurrent {
  if (_paused || _observed == nil) return;
  id contents = _observed.contents;
  if (contents != nil &&
      CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
    [self capture:(__bridge IOSurfaceRef)contents];
  }
}

// The layer whose contents is Flutter's IOSurface; FlutterView replaces it
// rarely, so a slow scan keeps the observation current.
- (void)observeSurfaceLayer {
  CALayer* found = nil;
  NSMutableArray<CALayer*>* stack = [NSMutableArray array];
  if (_contentView.layer != nil) [stack addObject:_contentView.layer];
  while (stack.count > 0) {
    CALayer* layer = stack.lastObject;
    [stack removeLastObject];
    id contents = layer.contents;
    if (contents != nil &&
        CFGetTypeID((__bridge CFTypeRef)contents) == IOSurfaceGetTypeID()) {
      found = layer;
      break;
    }
    [stack addObjectsFromArray:layer.sublayers ?: @[]];
  }
  if (found == nil || found == _observed) return;
  if (_observed != nil) {
    [_observed removeObserver:self forKeyPath:@"contents" context:kContentsContext];
  }
  _observed = found;
  [_observed addObserver:self
              forKeyPath:@"contents"
                 options:NSKeyValueObservingOptionInitial
                 context:kContentsContext];
}

- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {
  if (context != kContentsContext) {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    return;
  }
  id contents = ((CALayer*)object).contents;
  if (_paused || contents == nil ||
      CFGetTypeID((__bridge CFTypeRef)contents) != IOSurfaceGetTypeID()) {
    return;
  }
  [self capture:(__bridge IOSurfaceRef)contents];
}

- (void)ensurePoolFor:(IOSurfaceRef)source {
  const size_t width = IOSurfaceGetWidth(source);
  const size_t height = IOSurfaceGetHeight(source);
  if (_pool[0] != NULL && IOSurfaceGetWidth(_pool[0]) == width &&
      IOSurfaceGetHeight(_pool[0]) == height &&
      IOSurfaceGetPixelFormat(_pool[0]) == IOSurfaceGetPixelFormat(source)) {
    return;
  }
  [_lock lock];
  _generation += 1;
  const uint32_t generation = _generation;
  for (int i = 0; i < AUD_MACH_POOL_SIZE; ++i) {
    if (_pool[i] != NULL) CFRelease(_pool[i]);
    NSDictionary* properties = @{
      (id)kIOSurfaceWidth : @(width),
      (id)kIOSurfaceHeight : @(height),
      (id)kIOSurfaceBytesPerElement : @(IOSurfaceGetBytesPerElement(source)),
      (id)kIOSurfacePixelFormat : @(IOSurfaceGetPixelFormat(source)),
    };
    _pool[i] = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    _free[i] = YES;
  }
  [_lock unlock];
  const double scale = _contentView.window.backingScaleFactor;
  for (uint32_t i = 0; i < AUD_MACH_POOL_SIZE; ++i) {
    AudMachSurface message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits =
        MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = _channel.pluginPort;
    message.header.msgh_id = AUD_MACH_SURFACE;
    message.body.msgh_descriptor_count = 1;
    message.port.name = IOSurfaceCreateMachPort(_pool[i]);
    message.port.disposition = MACH_MSG_TYPE_MOVE_SEND;
    message.port.type = MACH_MSG_PORT_DESCRIPTOR;
    message.instance = _instance;
    message.index = i;
    message.generation = generation;
    message.width = (uint32_t)width;
    message.height = (uint32_t)height;
    message.scale = scale;
    if (mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
                 sizeof(message), 0, MACH_PORT_NULL, 100, MACH_PORT_NULL) !=
        KERN_SUCCESS) {
      mach_port_deallocate(mach_task_self(), message.port.name);
    }
  }
}

- (void)capture:(IOSurfaceRef)source {
  [self ensurePoolFor:source];
  [_lock lock];
  int index = -1;
  for (int n = 0; n < AUD_MACH_POOL_SIZE; ++n) {
    const int candidate = (int)((_next + n) % AUD_MACH_POOL_SIZE);
    if (_free[candidate] && !IOSurfaceIsInUse(_pool[candidate])) {
      index = candidate;
      break;
    }
  }
  if (index < 0) {
    _recapture = YES;
    [_lock unlock];
    _framesDropped += 1;
    return;
  }
  _free[index] = NO;
  _next = (uint32_t)(index + 1);
  const uint32_t generation = _generation;
  IOSurfaceRef target = _pool[index];
  CFRetain(target);
  [_lock unlock];
  CFRetain(source);
  // Flutter reuses a surface only when it is not in use; the count keeps
  // the frame until the copy has read it.
  IOSurfaceIncrementUseCount(source);
  const uint64_t frame = ++_frame;
  _framesSent += 1;
  const mach_port_t pluginPort = _channel.pluginPort;
  const uint32_t instance = _instance;
  __weak AudEditorBridge* weakSelf = self;
  dispatch_async(_channel.queue, ^{
    IOSurfaceLock(source, kIOSurfaceLockReadOnly, NULL);
    IOSurfaceLock(target, 0, NULL);
    const size_t rows = MIN(IOSurfaceGetHeight(source), IOSurfaceGetHeight(target));
    const size_t sourceStride = IOSurfaceGetBytesPerRow(source);
    const size_t targetStride = IOSurfaceGetBytesPerRow(target);
    const size_t bytes = MIN(sourceStride, targetStride);
    const uint8_t* from = IOSurfaceGetBaseAddress(source);
    uint8_t* to = IOSurfaceGetBaseAddress(target);
    for (size_t row = 0; row < rows; ++row) {
      memcpy(to + row * targetStride, from + row * sourceStride, bytes);
    }
    IOSurfaceUnlock(target, 0, NULL);
    IOSurfaceUnlock(source, kIOSurfaceLockReadOnly, NULL);
    IOSurfaceDecrementUseCount(source);
    CFRelease(source);
    CFRelease(target);
    AudMachFrame message;
    memset(&message, 0, sizeof(message));
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = pluginPort;
    message.header.msgh_id = AUD_MACH_FRAME;
    message.instance = instance;
    message.index = (uint32_t)index;
    message.generation = generation;
    message.frame = frame;
    message.captured = AudNowNs();
    // A frame the plugin never receives is never released: its surface
    // goes back into the pool here.
    if (mach_msg(&message.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(message),
                 0, MACH_PORT_NULL, 100, MACH_PORT_NULL) != KERN_SUCCESS) {
      [weakSelf releaseIndex:(uint32_t)index generation:generation];
    }
  });
}

@end
