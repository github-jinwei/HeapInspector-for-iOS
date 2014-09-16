//
//  NSObject+HeapInspector.m
//
//  Created by Christian Menschel on 06.08.14.
//  Copyright (c) 2014 tapwork. All rights reserved.
//
#import <libkern/OSAtomic.h>
#import <pthread.h>
#import <Foundation/Foundation.h>
#import "NSObject+HeapInspector.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <execinfo.h>

static CFMutableDictionaryRef backtraceDict;
static OSSpinLock backtraceDictLock;
static bool isRecording;
static bool swizzleActive;
static const char *recordClassPrefix;

static inline bool canRecordObject(Class cls);

//static inline void SwizzleInstanceMethod(Class c, SEL orig, SEL new)
//{
//    Method origMethod = class_getInstanceMethod(c, orig);
//    Method newMethod = class_getInstanceMethod(c, new);
//    method_exchangeImplementations(origMethod, newMethod);
//}

static inline void SwizzleClassMethod(Class c, SEL orig, SEL new)
{
    Method origMethod = class_getClassMethod(c, orig);
    Method newMethod = class_getClassMethod(c, new);
    method_exchangeImplementations(origMethod, newMethod);
}

static CFStringRef getCFString(char *charValue) {
    return CFStringCreateWithCString(NULL, charValue, kCFStringEncodingUTF8);
}

static CFStringRef cleanStackValue(char *stack) {
    CFStringRef cString = getCFString(stack);
  
    CFStringRef sep = getCFString("+[");
    CFArrayRef parts = CFStringCreateArrayBySeparatingStrings(NULL, cString, sep);
    if (CFArrayGetCount(parts) <= 1) {
        // If "+" class method didnt work. try "-" instance method
        sep = getCFString("-[");
        parts = CFStringCreateArrayBySeparatingStrings(NULL, cString, sep);
    }
    
    if (CFArrayGetCount(parts) > 1) {
        CFStringRef stack = (CFStringRef)CFArrayGetValueAtIndex(parts, 1);
        CFMutableStringRef val = CFStringCreateMutableCopy(NULL, 255, sep);
        CFStringAppend(val, stack);
        CFStringFindAndReplace(val,
                               getCFString("tw_alloc"),
                               getCFString("alloc"),
                               CFRangeMake(0, CFStringGetLength(val)),
                               kCFCompareNonliteral);
        
        return val;
    }
    
    return NULL;
}

static bool canRegisterBacktrace(char *stack) {
    CFStringRef cString = getCFString(stack);
    
    // Exclude the HINSP Class Prefix (that's ourself)
    CFRange range = CFStringFind(cString, getCFString("HINSP"), kCFCompareCaseInsensitive);
    if (range.location != kCFNotFound) {
        return false;
    }
    
    return true;
}

static CFArrayRef getBacktrace() {
    CFMutableArrayRef stack = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    void *bt[1024];
    int bt_size;
    char **bt_syms;
    bt_size = backtrace(bt, 1024);
    bt_syms = backtrace_symbols(bt, bt_size);
    for (int i = 0; i < bt_size; i++) {
        CFStringRef cString = cleanStackValue(bt_syms[i]);
        if (cString) {
            if (canRegisterBacktrace(bt_syms[i]) == true) {
                CFArrayAppendValue(stack, cString);
            } else {
                stack = NULL;
                break;
            }
        }
    }

    free(bt_syms);
    
    return stack;
}

static void registerBacktraceForObject(void *obj, char *type) {
    CFArrayRef backtrace = getBacktrace();
    OSSpinLockLock(&backtraceDictLock);
    
    char key[255];
    sprintf(key,"%p",obj);
    CFStringRef cfKey = getCFString(key);
    if (cfKey &&
        backtrace &&
        CFArrayGetCount(backtrace) > 0) {
        if (!backtraceDict) {
            backtraceDict = CFDictionaryCreateMutable(NULL,
                                                      0,
                                                      &kCFTypeDictionaryKeyCallBacks,
                                                      &kCFTypeDictionaryValueCallBacks);
        }
        CFMutableArrayRef history = (CFMutableArrayRef)CFDictionaryGetValue(backtraceDict, cfKey);
        if (!history) {
            history = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        }
        CFMutableDictionaryRef item = CFDictionaryCreateMutable(NULL,
                                                                0,
                                                                &kCFTypeDictionaryKeyCallBacks,
                                                                &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(item, getCFString("type"), getCFString(type));
        CFDictionarySetValue(item, getCFString("last_trace"), CFArrayGetValueAtIndex(backtrace, 0));
        CFDictionarySetValue(item, getCFString("all_traces"), backtrace);
        CFArrayAppendValue(history, item);
        CFDictionarySetValue(backtraceDict, cfKey, history);
    }
    OSSpinLockUnlock(&backtraceDictLock);
}

// SEE more http://clang.llvm.org/docs/AutomaticReferenceCounting.html
// or http://clang.llvm.org/doxygen/structclang_1_1CodeGen_1_1ARCEntrypoints.html
id objc_retain(id value) {
    if (value) {
        const char *className = object_getClassName(value);
        bool canRec = canRecordObject(object_getClass(value));
        if (canRec) {
            printf("retain %s <%p>\n",className, value);
            registerBacktraceForObject(value, "retain");
        }
    }
   
    SEL sel = sel_getUid("retain");
    objc_msgSend(value, sel);
   
    return value;
}

id objc_storeStrong(id *object, id value) {
    if (value) {
        const char *className = object_getClassName(value);
        bool canRec = canRecordObject(object_getClass(value));
        if (canRec) {
            printf("storeStrong %s <%p>\n",className, value);
            registerBacktraceForObject(value, "storeStrong");
        }
    }
    value = [value retain];
    id oldValue = *object;
    *object = value;
    [oldValue release];
    return value;
}

id objc_retainBlock(id value) {
    if (value) {
        const char *className = object_getClassName(value);
        bool canRec = canRecordObject(object_getClass(value));
        if (canRec) {
            printf("retainBlock %s <%p>\n",className, value);
            registerBacktraceForObject(value, "retainBlock");
        }
    }
    SEL sel = sel_getUid("copy");
    objc_msgSend(value, sel);
    
    return value;
}

id objc_release(id value) {
    if (value) {
        const char *className = object_getClassName(value);
        bool canRec = canRecordObject(object_getClass(value));
        if (canRec) {
            printf("release %s <%p>\n",className, value);
            registerBacktraceForObject(value, "release");
        }
    }
    
    SEL sel = sel_getUid("release");
    objc_msgSend(value, sel);
    // we could could even nil out (like weak) if retaincount is zero
    
    return value;
}

id objc_retainAutorelease(id value) {
    if (value) {
        const char *className = object_getClassName(value);
        bool canRec = canRecordObject(object_getClass(value));
        if (canRec) {
            printf("retainAutorelease %s <%p>\n",className, value);
            registerBacktraceForObject(value, "retainAutorelease");
        }
    }
    
    SEL selRetain = sel_getUid("retain");
    objc_msgSend(value, selRetain);
    SEL selAutorelease = sel_getUid("autorelease");
    objc_msgSend(value, selAutorelease);
    
    return value;
}

id objc_autorelease(id value) {
    if (value) {
        const char *className = object_getClassName(value);
        bool canRec = canRecordObject(object_getClass(value));
        if (canRec) {
            printf("autorelease %s <%p>\n",className, value);
            registerBacktraceForObject(value, "autorelease");
        }
    }
    
    SEL selAutorelease = sel_getUid("autorelease");
    objc_msgSend(value, selAutorelease);
    
    return value;
}

id objc_autoreleaseReturnValue(id value) {
    if (value) {
        const char *className = object_getClassName(value);
        bool canRec = canRecordObject(object_getClass(value));
        if (canRec) {
            printf("autoreleaseReturnValue %s <%p>\n",className, value);
            registerBacktraceForObject(value, "autoreleaseReturnValue");
        }
    }
    
    SEL selAutorelease = sel_getUid("autorelease");
    objc_msgSend(value, selAutorelease);
    
    return value;
}



static inline void cleanup()
{
    if (backtraceDict) {
        OSSpinLockLock(&backtraceDictLock);
        CFDictionaryRemoveAllValues(backtraceDict);
        OSSpinLockUnlock(&backtraceDictLock);
    }
}

static inline bool canRecordObject(Class cls)
{
    bool canRecord = true;
    const char *name = class_getName(cls);
    if (recordClassPrefix && name) {
        canRecord = (strncmp(name, recordClassPrefix, strlen(recordClassPrefix)) == 0);
    }
    
    if (isRecording == false) {
        canRecord = false;
    }
    
    return canRecord;
}

static inline void runLoopActivity(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
    if (activity & kCFRunLoopExit) {
    }
}


@implementation NSObject (HeapInspector)

+ (void)swizzle
{
    swizzleActive = true;
    SwizzleClassMethod([self class], NSSelectorFromString(@"alloc"), @selector(tw_alloc));
}

+ (id)tw_alloc
{
    bool canRec = canRecordObject([self class]);
    if (canRec) {
        const char *className = class_getName(self);
        printf("alloc %s\n",className);
    }
    id obj = [[self class] tw_alloc];
    if (canRec) {
        registerBacktraceForObject(obj, "alloc");
    }

    return obj;
}

- (void)addRunLoopObserver
{
    static CFRunLoopObserverRef runLoopObserver;
    if (runLoopObserver == nil) {
        runLoopObserver = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault,
                                                             kCFRunLoopAllActivities,
                                                             YES,
                                                             0,
                                                             ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity)
                                                             {
                                                                 runLoopActivity(observer, activity);
                                                             });
        CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, kCFRunLoopDefaultMode);
    }
}

#pragma mark - Public methods
+ (void)beginSnapshot
{
    [[self class] beginSnapshotWithClassPrefix:nil];
}

+ (void)beginSnapshotWithClassPrefix:(NSString*)prefix
{
    isRecording = true;
    cleanup();
    
    if (prefix) {
        recordClassPrefix = [prefix UTF8String];
    }
    
    if (!swizzleActive) {
        [[self class] swizzle];
    }
}

+ (void)endSnapshot
{
    isRecording = false;
}

+ (void)resumeSnapshot
{
    isRecording = true;
}

+ (NSArray *)referenceHistoryForObject:(id)obj
{
    char key[255];
    sprintf(key,"%p",(void *)obj);
    CFStringRef cfKey = getCFString(key);
    CFArrayRef cfHistory = CFDictionaryGetValue(backtraceDict, cfKey);
    NSArray *history = [(NSArray *)cfHistory copy];
    
    return history;
}


@end
