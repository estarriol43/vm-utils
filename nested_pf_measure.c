#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

#define GIB_SIZE (1ULL * 1024 * 1024 * 1024)

// Helper to get minor page faults using getrusage
long get_minor_page_faults() {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) == 0) {
        return usage.ru_minflt;
    }
    return -1;
}

// Helper to calculate time difference in nanoseconds
uint64_t get_elapsed_ns(struct timespec start, struct timespec end) {
    return (uint64_t)(end.tv_sec - start.tv_sec) * 1000000000ULL +
           (uint64_t)(end.tv_nsec - start.tv_nsec);
}

// Comparison function for sorting uint64_t array
int compare_uint64(const void *a, const void *b) {
    uint64_t val_a = *(const uint64_t *)a;
    uint64_t val_b = *(const uint64_t *)b;
    if (val_a < val_b) return -1;
    if (val_a > val_b) return 1;
    return 0;
}

// Helper to calculate and print detailed latency stats
void print_latency_stats(uint64_t *latencies, size_t count, const char *label) {
    if (count == 0) return;

    // Sort the latencies to calculate percentiles
    qsort(latencies, count, sizeof(uint64_t), compare_uint64);

    double sum = 0;
    for (size_t i = 0; i < count; i++) {
        sum += latencies[i];
    }
    double mean = sum / count;

    size_t idx_p50 = count * 50 / 100;
    size_t idx_p90 = count * 90 / 100;
    size_t idx_p95 = count * 95 / 100;
    size_t idx_p99 = count * 99 / 100;
    size_t idx_p999 = count * 999 / 1000;

    if (idx_p50 >= count) idx_p50 = count - 1;
    if (idx_p90 >= count) idx_p90 = count - 1;
    if (idx_p95 >= count) idx_p95 = count - 1;
    if (idx_p99 >= count) idx_p99 = count - 1;
    if (idx_p999 >= count) idx_p999 = count - 1;

    // Calculate tail means (expected shortfall / average of worst x%)
    double sum_p95_tail = 0;
    size_t count_p95_tail = count - idx_p95;
    for (size_t i = idx_p95; i < count; i++) {
        sum_p95_tail += latencies[i];
    }
    double mean_p95_tail = count_p95_tail > 0 ? (sum_p95_tail / count_p95_tail) : 0;

    double sum_p99_tail = 0;
    size_t count_p99_tail = count - idx_p99;
    for (size_t i = idx_p99; i < count; i++) {
        sum_p99_tail += latencies[i];
    }
    double mean_p99_tail = count_p99_tail > 0 ? (sum_p99_tail / count_p99_tail) : 0;

    printf("Latency stats for %s (%zu samples):\n", label, count);
    printf("  Mean:           %12.2f ns\n", mean);
    printf("  Min:            %12.2f ns\n", (double)latencies[0]);
    printf("  p50 (Median):   %12.2f ns\n", (double)latencies[idx_p50]);
    printf("  p90:            %12.2f ns\n", (double)latencies[idx_p90]);
    printf("  p95:            %12.2f ns\n", (double)latencies[idx_p95]);
    printf("  p99:            %12.2f ns\n", (double)latencies[idx_p99]);
    printf("  p99.9:          %12.2f ns\n", (double)latencies[idx_p999]);
    printf("  Max:            %12.2f ns\n", (double)latencies[count - 1]);
    printf("  p95 Tail Mean:  %12.2f ns (avg of worst 5%%)\n", mean_p95_tail);
    printf("  p99 Tail Mean:  %12.2f ns (avg of worst 1%%)\n", mean_p99_tail);
}

int main(int argc, char *argv[]) {
    if (argc > 1 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
        printf("Usage: %s [size_in_mb] [--huge]\n", argv[0]);
        printf("  size_in_mb: size of mapping in MB (default: 1024)\n");
        printf("  --huge:     use 2MB huge pages (default: 4KB pages)\n");
        return 0;
    }

    size_t alloc_size = GIB_SIZE;
    if (argc > 1) {
        double mb = atof(argv[1]);
        if (mb > 0) {
            alloc_size = (size_t)(mb * 1024 * 1024);
        }
    }

    int use_huge = 0;
    if (argc > 2 && (strcmp(argv[2], "--huge") == 0)) {
        use_huge = 1;
    } else if (argc > 1 && (strcmp(argv[1], "--huge") == 0)) {
        use_huge = 1;
    }

    size_t page_size = use_huge ? (2ULL * 1024 * 1024) : 4096;

    // Align alloc_size to page_size
    alloc_size = (alloc_size + page_size - 1) & ~(page_size - 1);

    printf("Allocating %zu bytes (%.2f MB) of anonymous memory (Page Size: %zu KB)...\n",
           alloc_size, (double)alloc_size / (1024 * 1024), page_size / 1024);

    int mmap_flags = MAP_PRIVATE | MAP_ANONYMOUS;
    if (use_huge) {
#ifndef MAP_HUGETLB
#define MAP_HUGETLB 0x40000
#endif
#ifndef MAP_HUGE_SHIFT
#define MAP_HUGE_SHIFT 26
#endif
#ifndef MAP_HUGE_2MB
#define MAP_HUGE_2MB (21 << MAP_HUGE_SHIFT)
#endif
        mmap_flags |= MAP_HUGETLB | MAP_HUGE_2MB;
    }

    // Use mmap to allocate anonymous, private memory.
    volatile uint8_t *addr = mmap(NULL, alloc_size, PROT_READ | PROT_WRITE,
                                  mmap_flags, -1, 0);
    if (addr == MAP_FAILED) {
        perror("mmap failed");
        return 1;
    }

    // Disable transparent huge pages (THP) if not explicitly using huge pages
    if (!use_huge) {
        madvise((void *)addr, alloc_size, MADV_NOHUGEPAGE);
    }

    printf("Memory mapped at virtual address: %p\n", (void *)addr);
    printf("Writing to every %zu KB page to trigger page faults...\n\n", page_size / 1024);

    size_t total_pages = alloc_size / page_size;
    uint64_t *latencies_1 = malloc(total_pages * sizeof(uint64_t));
    uint64_t *latencies_2 = malloc(total_pages * sizeof(uint64_t));
    uint64_t *overhead_latencies = malloc(total_pages * sizeof(uint64_t));

    if (!latencies_1 || !latencies_2 || !overhead_latencies) {
        fprintf(stderr, "Failed to allocate memory for latency tracking arrays\n");
        if (latencies_1) free(latencies_1);
        if (latencies_2) free(latencies_2);
        if (overhead_latencies) free(overhead_latencies);
        munmap((void *)addr, alloc_size);
        return 1;
    }

    // Pre-fault the latency tracking arrays to prevent them from triggering page faults during measurement sweeps
    memset(latencies_1, 0, total_pages * sizeof(uint64_t));
    memset(latencies_2, 0, total_pages * sizeof(uint64_t));
    memset(overhead_latencies, 0, total_pages * sizeof(uint64_t));

    // Warm up the timers and get initial page faults
    long faults_before_1 = get_minor_page_faults();
    struct timespec start_1, end_1;

    clock_gettime(CLOCK_MONOTONIC, &start_1);
    // Write sweep 1 (First access: triggers guest page faults and nested page faults)
    for (size_t i = 0; i < total_pages; i++) {
        size_t offset = i * page_size;
        struct timespec p_start, p_end;
        clock_gettime(CLOCK_MONOTONIC, &p_start);
        addr[offset] = 0xAA;
        clock_gettime(CLOCK_MONOTONIC, &p_end);
        latencies_1[i] = get_elapsed_ns(p_start, p_end);
    }
    clock_gettime(CLOCK_MONOTONIC, &end_1);

    long faults_after_1 = get_minor_page_faults();
    uint64_t duration_ns_1 = get_elapsed_ns(start_1, end_1);
    long actual_faults_1 = faults_after_1 - faults_before_1;

    printf("--- SWEEP 1 (Cold Access: Triggers Page Faults) ---\n");
    printf("Elapsed time:         %12.6f ms\n", (double)duration_ns_1 / 1e6);
    printf("Minor page faults:    %12ld\n", actual_faults_1);
    if (actual_faults_1 > 0) {
        printf("Avg latency per page: %12.2f ns\n", (double)duration_ns_1 / total_pages);
    }

    // Write sweep 2 (Second access: pages are already mapped/resident in memory)
    long faults_before_2 = get_minor_page_faults();
    struct timespec start_2, end_2;

    clock_gettime(CLOCK_MONOTONIC, &start_2);
    for (size_t i = 0; i < total_pages; i++) {
        size_t offset = i * page_size;
        struct timespec p_start, p_end;
        clock_gettime(CLOCK_MONOTONIC, &p_start);
        addr[offset] = 0xBB;
        clock_gettime(CLOCK_MONOTONIC, &p_end);
        latencies_2[i] = get_elapsed_ns(p_start, p_end);
    }
    clock_gettime(CLOCK_MONOTONIC, &end_2);

    long faults_after_2 = get_minor_page_faults();
    uint64_t duration_ns_2 = get_elapsed_ns(start_2, end_2);
    long actual_faults_2 = faults_after_2 - faults_before_2;

    printf("\n--- SWEEP 2 (Warm Access: Cached / Already Mapped) ---\n");
    printf("Elapsed time:         %12.6f ms\n", (double)duration_ns_2 / 1e6);
    printf("Minor page faults:    %12ld\n", actual_faults_2);
    printf("Avg latency per page: %12.2f ns\n", (double)duration_ns_2 / total_pages);

    // Calculate approximate page fault overhead
    if (duration_ns_1 > duration_ns_2) {
        uint64_t overhead_ns = duration_ns_1 - duration_ns_2;
        printf("\n--- OVERHEAD ESTIMATION ---\n");
        printf("Est. total page fault overhead: %12.6f ms\n", (double)overhead_ns / 1e6);
        printf("Est. average time per page fault: %10.2f ns\n", (double)overhead_ns / total_pages);
    }

    // Calculate estimated per-page page fault overhead
    for (size_t i = 0; i < total_pages; i++) {
        overhead_latencies[i] = (latencies_1[i] > latencies_2[i]) ? (latencies_1[i] - latencies_2[i]) : 0;
    }

    printf("\n--- LATENCY DISTRIBUTIONS ---\n");
    print_latency_stats(latencies_1, total_pages, "SWEEP 1 (Cold Access)");
    printf("\n");
    print_latency_stats(latencies_2, total_pages, "SWEEP 2 (Warm Access)");
    printf("\n");
    print_latency_stats(overhead_latencies, total_pages, "Estimated Page Fault Overhead");

    // Clean up
    free(latencies_1);
    free(latencies_2);
    free(overhead_latencies);

    if (munmap((void *)addr, alloc_size) == -1) {
        perror("munmap failed");
    }

    return 0;
}
