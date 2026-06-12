#ifndef NetProcStats_h
#define NetProcStats_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NetProcRow : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) pid_t pid;
@property (nonatomic) uint64_t bytesInPerSec;
@property (nonatomic) uint64_t bytesOutPerSec;
@end

// Per-process network rates from the private NetworkStatistics framework —
// the same data source nettop reads, but in-process: no child process to
// manage or leak, and a fraction of the CPU cost.
//
// Not thread-safe: call every method on the queue passed to the initializer.
// Counts callbacks and query completions run on that queue too.
@interface NetProcStats : NSObject

- (instancetype)initWithQueue:(dispatch_queue_t)queue;

// NO if the private framework can't be loaded.
- (BOOL)start;
- (void)stop;

// Reports each process's rate since the previous query, sorted busiest
// first, excluding loopback flows. Passes nil until two queries have
// happened (the first one establishes the baseline).
- (void)queryRates:(void (^)(NSArray<NetProcRow *> * _Nullable rows))completion;

@end

NS_ASSUME_NONNULL_END

#endif /* NetProcStats_h */
