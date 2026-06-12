#import "NetProcStats.h"
#include <dlfcn.h>
#include <time.h>

typedef void *NStatManagerRef;
typedef void *NStatSourceRef;
typedef NStatManagerRef (*NStatManagerCreateFn)(CFAllocatorRef, dispatch_queue_t, void (^)(NStatSourceRef, void *));
typedef void (*NStatManagerDestroyFn)(NStatManagerRef);
typedef int (*NStatManagerAddAllWithFilterFn)(NStatManagerRef, uint64_t, uint64_t);
typedef void (*NStatManagerQueryAllFn)(NStatManagerRef, void (^)(void));
typedef void (*NStatSourceSetBlockFn)(NStatSourceRef, void (^)(CFDictionaryRef));
typedef void (*NStatSourceSetRemovedFn)(NStatSourceRef, void (^)(void));

static NStatManagerCreateFn sManagerCreate;
static NStatManagerDestroyFn sManagerDestroy;
static NStatManagerAddAllWithFilterFn sAddAllTCP;
static NStatManagerAddAllWithFilterFn sAddAllUDP;
static NStatManagerQueryAllFn sQueryUpdate;
static NStatSourceSetBlockFn sSetCountsBlock;
static NStatSourceSetRemovedFn sSetRemovedBlock;

static BOOL loadNetworkStatistics(void) {
    static dispatch_once_t once;
    static BOOL loaded = NO;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/NetworkStatistics.framework/NetworkStatistics", RTLD_LAZY);
        if (!handle) {
            return;
        }
        sManagerCreate = dlsym(handle, "NStatManagerCreate");
        sManagerDestroy = dlsym(handle, "NStatManagerDestroy");
        sAddAllTCP = dlsym(handle, "NStatManagerAddAllTCPWithFilter");
        sAddAllUDP = dlsym(handle, "NStatManagerAddAllUDPWithFilter");
        sQueryUpdate = dlsym(handle, "NStatManagerQueryAllSourcesUpdate");
        sSetCountsBlock = dlsym(handle, "NStatSourceSetCountsBlock");
        sSetRemovedBlock = dlsym(handle, "NStatSourceSetRemovedBlock");
        loaded = sManagerCreate && sManagerDestroy && sAddAllTCP && sAddAllUDP
            && sQueryUpdate && sSetCountsBlock && sSetRemovedBlock;
    });
    return loaded;
}

@implementation NetProcRow
@end

// One tracked kernel flow (a TCP or UDP source).
@interface NetSrcState : NSObject
@property (nonatomic) uint64_t rx;
@property (nonatomic) uint64_t tx;
@property (nonatomic) uint64_t lastRx;
@property (nonatomic) uint64_t lastTx;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic) pid_t pid;
@property (nonatomic) BOOL hasBaseline;
@property (nonatomic) BOOL loopback;
@end

@implementation NetSrcState
@end

@implementation NetProcStats {
    dispatch_queue_t _queue;
    NStatManagerRef _manager;
    NSMutableDictionary<NSValue *, NetSrcState *> *_sources;
    uint64_t _lastQueryTimeNs;
}

- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    self = [super init];
    if (self) {
        _queue = queue;
    }
    return self;
}

- (void)dealloc {
    if (_manager) {
        sManagerDestroy(_manager);
    }
}

- (BOOL)start {
    if (_manager) {
        return YES;
    }
    if (!loadNetworkStatistics()) {
        return NO;
    }
    _sources = [NSMutableDictionary dictionary];
    _lastQueryTimeNs = 0;

    // The blocks capture the dictionary rather than self so a stopped
    // instance can't be retained by stale framework callbacks.
    NSMutableDictionary<NSValue *, NetSrcState *> *sources = _sources;
    _manager = sManagerCreate(kCFAllocatorDefault, _queue, ^(NStatSourceRef src, void *unused) {
        NSValue *key = [NSValue valueWithPointer:src];
        NetSrcState *state = [NetSrcState new];
        sources[key] = state;
        sSetCountsBlock(src, ^(CFDictionaryRef countsRef) {
            NSDictionary *counts = (__bridge NSDictionary *)countsRef;
            state.rx = [counts[@"rxBytes"] unsignedLongLongValue];
            state.tx = [counts[@"txBytes"] unsignedLongLongValue];
            state.pid = [counts[@"processID"] intValue];
            state.loopback = [counts[@"ifLoopback"] boolValue];
            NSString *name = counts[@"processName"];
            if (name) {
                state.name = name;
            }
        });
        sSetRemovedBlock(src, ^{
            [sources removeObjectForKey:key];
        });
    });
    if (!_manager) {
        _sources = nil;
        return NO;
    }
    sAddAllTCP(_manager, 0, 0);
    sAddAllUDP(_manager, 0, 0);
    return YES;
}

- (void)stop {
    if (_manager) {
        sManagerDestroy(_manager);
        _manager = NULL;
    }
    _sources = nil;
    _lastQueryTimeNs = 0;
}

- (void)queryRates:(void (^)(NSArray<NetProcRow *> * _Nullable))completion {
    if (!_manager) {
        completion(nil);
        return;
    }
    __weak NetProcStats *weakSelf = self;
    // The completion runs on _queue after every source's counts block fired.
    sQueryUpdate(_manager, ^{
        NetProcStats *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_manager) {
            completion(nil);
            return;
        }
        completion([strongSelf collectRates]);
    });
}

// Runs on _queue.
- (NSArray<NetProcRow *> * _Nullable)collectRates {
    uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    BOOL haveInterval = _lastQueryTimeNs != 0 && now > _lastQueryTimeNs;
    double elapsedSeconds = haveInterval ? (double)(now - _lastQueryTimeNs) / 1e9 : 0;
    _lastQueryTimeNs = now;

    NSMutableDictionary<NSNumber *, NetProcRow *> *perProcess =
        haveInterval ? [NSMutableDictionary dictionary] : nil;

    for (NetSrcState *state in _sources.allValues) {
        uint64_t deltaRx = 0;
        uint64_t deltaTx = 0;
        // A counter that went backwards means the source was reused; treat
        // the current value as the new baseline.
        if (state.hasBaseline && state.rx >= state.lastRx && state.tx >= state.lastTx) {
            deltaRx = state.rx - state.lastRx;
            deltaTx = state.tx - state.lastTx;
        }
        state.lastRx = state.rx;
        state.lastTx = state.tx;
        state.hasBaseline = YES;

        // Loopback is local IPC, not network traffic, matching the menu
        // bar's per-interface totals.
        if (!perProcess || state.loopback || deltaRx + deltaTx == 0 || !state.name) {
            continue;
        }
        NSNumber *pidKey = @(state.pid);
        NetProcRow *row = perProcess[pidKey];
        if (!row) {
            row = [NetProcRow new];
            row.name = state.name;
            row.pid = state.pid;
            perProcess[pidKey] = row;
        }
        row.bytesInPerSec += (uint64_t)((double)deltaRx / elapsedSeconds);
        row.bytesOutPerSec += (uint64_t)((double)deltaTx / elapsedSeconds);
    }

    if (!perProcess) {
        return nil; // first query only establishes baselines
    }
    return [perProcess.allValues sortedArrayUsingComparator:^(NetProcRow *a, NetProcRow *b) {
        uint64_t totalA = a.bytesInPerSec + a.bytesOutPerSec;
        uint64_t totalB = b.bytesInPerSec + b.bytesOutPerSec;
        if (totalA == totalB) {
            return NSOrderedSame;
        }
        return totalA > totalB ? NSOrderedAscending : NSOrderedDescending;
    }];
}

@end
