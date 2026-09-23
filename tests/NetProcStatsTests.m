#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <time.h>
#include <assert.h>

static void *fixtureOpen(const char *path, int mode);
static void *fixtureSymbol(void *handle, const char *name);
static uint64_t fixtureTime(clockid_t clock);

// Keep the private-framework fixture local to this translation unit. The
// production code still uses dlopen/dlsym and the system clock normally.
#define dlopen fixtureOpen
#define dlsym fixtureSymbol
#define clock_gettime_nsec_np fixtureTime
// Including an implementation as a fixture makes Clang apply header-only
// nullability completeness diagnostics to otherwise valid .m definitions.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import "../NetProcStats.m"
#pragma clang diagnostic pop
#undef dlopen
#undef dlsym
#undef clock_gettime_nsec_np

static void (^sourceAdded)(NStatSourceRef, void *);
static void (^countsChanged)(CFDictionaryRef);
static void (^queryDone)(void);
static unsigned queryCount;
static uint64_t now = 1000000000;

static NStatManagerRef createManager(CFAllocatorRef allocator, dispatch_queue_t queue,
                                     void (^added)(NStatSourceRef, void *)) {
    (void)allocator; (void)queue;
    sourceAdded = [added copy];
    return (void *)1;
}
static void destroyManager(NStatManagerRef manager) { (void)manager; sourceAdded = nil; countsChanged = nil; }
static int addAll(NStatManagerRef manager, uint64_t a, uint64_t b) {
    (void)manager; (void)a; (void)b; return 0;
}
static void query(NStatManagerRef manager, void (^done)(void)) {
    (void)manager; queryCount++; queryDone = [done copy];
}
static void setCounts(NStatSourceRef source, void (^counts)(CFDictionaryRef)) {
    (void)source; countsChanged = [counts copy];
}
static void setRemoved(NStatSourceRef source, void (^removed)(void)) { (void)source; (void)removed; }
static uint64_t fixtureTime(clockid_t clock) { (void)clock; return now; }
static void *fixtureOpen(const char *path, int mode) { (void)path; (void)mode; return (void *)1; }
static void *fixtureSymbol(void *handle, const char *name) {
    (void)handle;
    if (!strcmp(name, "NStatManagerCreate")) return createManager;
    if (!strcmp(name, "NStatManagerDestroy")) return destroyManager;
    if (!strcmp(name, "NStatManagerAddAllTCPWithFilter")) return addAll;
    if (!strcmp(name, "NStatManagerAddAllUDPWithFilter")) return addAll;
    if (!strcmp(name, "NStatManagerQueryAllSourcesUpdate")) return query;
    if (!strcmp(name, "NStatSourceSetCountsBlock")) return setCounts;
    if (!strcmp(name, "NStatSourceSetRemovedBlock")) return setRemoved;
    return NULL;
}
static void setBytes(uint64_t bytes) {
    countsChanged((__bridge CFDictionaryRef)@{@"rxBytes": @(bytes), @"txBytes": @0,
        @"processID": @42, @"processName": @"fixture", @"ifLoopback": @NO});
}

int main(void) {
    @autoreleasepool {
        dispatch_queue_t queue = dispatch_queue_create("menustat.tests", DISPATCH_QUEUE_SERIAL);
        dispatch_sync(queue, ^{
            NetProcStats *stats = [[NetProcStats alloc] initWithQueue:queue];
            assert([stats start]);
            sourceAdded((void *)2, NULL);
            setBytes(100);
            __block unsigned completions = 0;
            [stats queryRates:^(NSArray<NetProcRow *> *rows) { assert(!rows); completions++; }];
            [stats queryRates:^(NSArray<NetProcRow *> *rows) { assert(!rows); completions++; }];
            assert(queryCount == 1 && completions == 1);
            queryDone();
            assert(completions == 2);

            now += 2000000000;
            setBytes(500);
            [stats queryRates:^(NSArray<NetProcRow *> *rows) {
                assert(rows.count == 1 && rows[0].bytesInPerSec == 200);
                completions++;
            }];
            queryDone();
            assert(completions == 3);

            [stats queryRates:^(NSArray<NetProcRow *> *rows) { assert(!rows); completions++; }];
            void (^stale)(void) = queryDone;
            [stats stop];
            assert([stats start]);
            [stats queryRates:^(NSArray<NetProcRow *> *rows) { assert(!rows); completions++; }];
            stale(); // Old completion must not collect or clear the new query.
            unsigned before = queryCount;
            [stats queryRates:^(NSArray<NetProcRow *> *rows) { assert(!rows); }];
            assert(queryCount == before);
            queryDone();
            assert(completions == 5);
            [stats stop];
            [stats queryRates:^(NSArray<NetProcRow *> *rows) { assert(!rows); completions++; }];
            assert(completions == 6);
        });
        puts("PASS: one network query in flight, elapsed rates, stop/restart, stale completions");
    }
}
