#ifndef RDPKIT_TEST_MEMORY_LIMIT_H
#define RDPKIT_TEST_MEMORY_LIMIT_H

#include <stdint.h>

/// Sets the memory footprint, in bytes, past which this test process stops; 0 turns the limit off.
void rdpkit_test_memory_limit_set(uint64_t byteCount);

#endif
