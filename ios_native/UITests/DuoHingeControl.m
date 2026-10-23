/*
BSD License

For WebDriverAgent software

Copyright (c) 2015-present, Facebook, Inc. All rights reserved.

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

 * Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

 * Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

 * Neither the name Facebook nor the names of its contributors may be used to
   endorse or promote products derived from this software without specific
   prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


Adapted from Appium WebDriverAgent XCUIDevice+FBHinge.m,
https://github.com/appium/WebDriverAgent/pull/1287 .
Test-only simulator bridge; never part of the app target.
*/
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#if TARGET_OS_SIMULATOR
@protocol DuoAngle <NSObject>
- (BOOL)isAngleValid;
- (float)angleDegrees;
@end

@protocol DuoAngleManager <NSObject>
+ (BOOL)isAvailable;
+ (BOOL)instancesRespondToSelector:(SEL)selector;
+ (instancetype)new;
- (void)startAngleUpdatesToQueue:(NSOperationQueue *)queue handler:(void (^)(id<DuoAngle>))handler;
- (void)stopAngleUpdates;
@end

static BOOL DuoInjectAngle(double target) {
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!library) return NO;
    CFDataRef (*serialize)(CFTypeRef, CFOptionFlags) = dlsym(library, "IOCFSerialize");
    CFTypeRef (*createEvent)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                            uint8_t *, CFIndex, uint32_t) = dlsym(library, "IOHIDEventCreateVendorDefinedEvent");
    CFTypeRef (*createClient)(CFAllocatorRef) = dlsym(library, "IOHIDEventSystemClientCreate");
    void (*dispatchEvent)(CFTypeRef, CFTypeRef) = dlsym(library, "IOHIDEventSystemClientDispatchEvent");
    BOOL dispatched = NO;
    CFDataRef data = NULL;
    CFTypeRef event = NULL;
    CFTypeRef client = NULL;
    if (serialize && createEvent && createClient && dispatchEvent) {
        NSDictionary *payload = @{
            @"provider": @"com.apple.Virtualization.VirtualMachines",
            @"source": @"hinge-slider-control",
            @"type": @"range",
            @"value": @(target)
        };
        data = serialize((__bridge CFTypeRef)payload, 1);
        if (data) {
            event = createEvent(kCFAllocatorDefault, mach_absolute_time(), 0xff61, 0x5b, 0,
                                (uint8_t *)CFDataGetBytePtr(data), CFDataGetLength(data), 0);
            client = createClient(kCFAllocatorDefault);
            if (event && client) {
                dispatchEvent(client, event);
                dispatched = YES;
            }
        }
    }
    if (client) CFRelease(client);
    if (event) CFRelease(event);
    if (data) CFRelease(data);
    dlclose(library);
    return dispatched;
}

/// Returns a sensor-confirmed angle, or NaN when unavailable/unsuccessful.
/// A target of -1 reads the sensor without changing the simulated hinge.
double DuoSetHingeAngle(double target) {
    @autoreleasepool {
        if (!isfinite(target) || target > 180 || (target < 0 && target != -1)) return NAN;
        static void *motionFramework;
        static dispatch_once_t loadMotionOnce;
        dispatch_once(&loadMotionOnce, ^{
            motionFramework = dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_LAZY);
        });
        if (!motionFramework) return NAN;
        Class<DuoAngleManager> managerClass = NSClassFromString(@"CMAngleManager");
        if (![managerClass respondsToSelector:@selector(isAvailable)] || ![managerClass isAvailable]
            || ![managerClass instancesRespondToSelector:@selector(startAngleUpdatesToQueue:handler:)]
            || ![managerClass instancesRespondToSelector:@selector(stopAngleUpdates)]) return NAN;

        id<DuoAngleManager> manager = [managerClass new];
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 1;
        NSCondition *condition = [NSCondition new];
        __block double measured = NAN;
        BOOL started = NO;
        @try {
            [manager startAngleUpdatesToQueue:queue handler:^(id<DuoAngle> angle) {
                if (![angle respondsToSelector:@selector(isAngleValid)]
                    || ![angle respondsToSelector:@selector(angleDegrees)] || !angle.isAngleValid) return;
                double value = angle.angleDegrees;
                if (!isfinite(value) || (target >= 0 && fabs(value - target) >= 1)) return;
                [condition lock];
                measured = value;
                [condition signal];
                [condition unlock];
            }];
            started = YES;
            if (target >= 0 && !DuoInjectAngle(target)) return NAN;
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
            [condition lock];
            while (!isfinite(measured) && [condition waitUntilDate:deadline]) {}
            double result = measured;
            [condition unlock];
            return result;
        } @finally {
            if (started) [manager stopAngleUpdates];
            [queue cancelAllOperations];
        }
    }
}
#else
double DuoSetHingeAngle(double target) { return NAN; }
#endif
