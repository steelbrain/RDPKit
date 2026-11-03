// Stops an RDPKit test process whose memory grows past a limit, before it runs the Mac out of
// memory: on 2026-11-02 a test runner grew to 111 GiB on a 64 GiB Mac, and macOS killed about 15
// services to make room before killing it. The whole suite stays under 2 GiB, so a process past
// 8 GiB is a test, or the code it tests, growing without bound.
//
// The test targets link this, so the constructor starts the watch in every process that loads
// them, however `swift test` was started, the children of exit tests included. Swift has no way
// to run code when a test bundle loads, hence C.
// RDPKIT_TEST_MEMORY_LIMIT_GIB sets another limit; 0 turns it off.

#include "RDPKitTestMemoryLimit.h"

#include <stdatomic.h>

static _Atomic uint64_t limitByteCount = 8ULL << 30;

void rdpkit_test_memory_limit_set(uint64_t byteCount) {
    atomic_store(&limitByteCount, byteCount);
}

#if defined(__APPLE__)
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// What macOS counts when memory runs out: dirty and compressed pages, not clean file pages.
static uint64_t footprintByteCount(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return info.phys_footprint;
}

static void *watchFootprint(void *unused) {
    (void)unused;
    for (;;) {
        uint64_t limit = atomic_load(&limitByteCount);
        uint64_t footprint = footprintByteCount();
        if (limit != 0 && footprint > limit) {
            char message[400];
            int length = snprintf(
                message, sizeof message,
                "RDPKit tests: this process uses %.1f GiB of memory, over its limit of %.1f GiB, so it "
                "stops before it runs the Mac out of memory. A test, or the code it tests, is growing "
                "without bound. RDPKIT_TEST_MEMORY_LIMIT_GIB sets another limit; 0 turns it off.\n",
                footprint / 1073741824.0, limit / 1073741824.0);
            // write(2) and _exit(2), not stdio and exit(3): another thread may hold stdio's lock.
            if (length > 0) {
                write(STDERR_FILENO, message, strnlen(message, sizeof message));
            }
            _exit(EXIT_FAILURE);
        }
        usleep(100000);
    }
    return NULL;
}

__attribute__((constructor)) static void startWatchingFootprint(void) {
    const char *setting = getenv("RDPKIT_TEST_MEMORY_LIMIT_GIB");
    if (setting != NULL) {
        char *end = NULL;
        double gibibytes = strtod(setting, &end);
        if (end != setting) {
            rdpkit_test_memory_limit_set(gibibytes > 0 ? (uint64_t)(gibibytes * 1073741824.0) : 0);
        }
    }
    pthread_t thread;
    if (pthread_create(&thread, NULL, watchFootprint, NULL) == 0) {
        pthread_detach(thread);
    }
}
#endif
