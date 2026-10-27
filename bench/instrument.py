"""Instrument generated/runtime C allocations within explicit benchmark regions."""
import argparse
from pathlib import Path
import re
import subprocess

PREFIX = r'''
#define _GNU_SOURCE
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>
#include <sys/mman.h>
static _Atomic int say_probe_active;
static _Atomic long long say_book_storage, say_workspace_storage;
#define SAY_ARRAY_BYTES(a) (sizeof(sl_arr) + (size_t)(a)->cap * (a)->esz)
static _Atomic long long say_probe_calls, say_probe_bytes, say_probe_gc_count, say_probe_gc_size, say_probe_map_count;
__attribute__((used,noinline)) void say_probe_begin(void) {
    atomic_store(&say_probe_calls, 0); atomic_store(&say_probe_bytes, 0);
    atomic_store(&say_probe_gc_count, 0); atomic_store(&say_probe_gc_size, 0); atomic_store(&say_probe_map_count, 0);
    atomic_store(&say_probe_active, 1);
}
__attribute__((used,noinline)) long long say_probe_end(void) { atomic_store(&say_probe_active, 0); return atomic_load(&say_probe_calls); }
__attribute__((used,noinline)) long long say_probe_gc(void) { return atomic_load(&say_probe_gc_count); }
__attribute__((used,noinline)) long long say_probe_gc_bytes(void) { return atomic_load(&say_probe_gc_size); }
__attribute__((used,noinline)) long long say_probe_native_bytes(void) { return atomic_load(&say_probe_bytes); }
__attribute__((used,noinline)) long long say_probe_maps(void) { return atomic_load(&say_probe_map_count); }
static void say_probe_native(size_t n) {
    if (atomic_load(&say_probe_active)) { atomic_fetch_add(&say_probe_calls, 1); atomic_fetch_add(&say_probe_bytes, (long long)n); }
}
static void *say_count_malloc(size_t n) { say_probe_native(n); return malloc(n); }
static void *say_count_calloc(size_t n, size_t s) { say_probe_native(n*s); return calloc(n,s); }
static void *say_count_realloc(void *p, size_t n) { say_probe_native(n); return realloc(p,n); }
static int say_count_posix_memalign(void **p, size_t alignment, size_t n) { say_probe_native(n); return posix_memalign(p,alignment,n); }
static void *say_count_mmap(void *p, size_t n, int prot, int flags, int fd, off_t off) {
    if (atomic_load(&say_probe_active)) { atomic_fetch_add(&say_probe_map_count, 1); atomic_fetch_add(&say_probe_bytes, (long long)n); }
    return mmap(p,n,prot,flags,fd,off);
}
#define malloc say_count_malloc
#define calloc say_count_calloc
#define realloc say_count_realloc
#define posix_memalign say_count_posix_memalign
#define mmap say_count_mmap
'''
SUFFIX = r'''
__attribute__((used,noinline)) long long say_probe_book_storage(void) { return atomic_load(&say_book_storage); }
__attribute__((used,noinline)) long long say_probe_workspace_storage(void) { return atomic_load(&say_workspace_storage); }
__attribute__((used,noinline)) long long say_probe_order_bytes(void) { return (long long)sizeof(sl_st_domain_Order); }
__attribute__((used,noinline)) long long say_probe_slot_bytes(void) { return (long long)sizeof(sl_st_domain_Slot); }
__attribute__((used,noinline)) long long say_probe_bucket_bytes(void) { return (long long)sizeof(sl_st_domain_Bucket); }
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("-o", required=True)
    args = parser.parse_args()
    target = Path(args.o)
    generated = target.with_suffix(".gen.c")
    subprocess.run(["slangc", args.source, "--emit-c", "-o", str(target)], check=True)
    source = generated.read_text()
    pattern = r"(static inline void \*sl_gc_alloc_impl\(.*?\)\s*\{)"
    source, count = re.subn(pattern, r"\1\n    if (atomic_load(&say_probe_active)) { atomic_fetch_add(&say_probe_gc_count, 1); atomic_fetch_add(&say_probe_gc_size, (long long)n); }", source, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError("installed runtime allocation entry point changed")
    book_arrays = ("bids", "asks", "slots", "index", "free_slots")
    book_size = "sizeof(*b) + b->digest.memory.cap + " + " + ".join(f"SAY_ARRAY_BYTES(b->{name})" for name in book_arrays)
    source, count = re.subn(r"(static void sl_domain_genesis\([^;]*?\) \{)", lambda m: m[1] + "\n atomic_store(&say_book_storage, " + book_size + ");", source, count=1)
    if count != 1:
        raise RuntimeError("book constructor symbol changed")
    work_arrays = ("fills", "updates", "postings", "entries", "holds", "deltas", "verify_seen", "slot_epochs", "slot_updates", "level_epochs", "level_totals", "hash.constants", "hash.schedule", "hash.words")
    work_size = "sizeof(_sl_rv) + _sl_rv.keys.memory.cap + _sl_rv.canonical.memory.cap + _sl_rv.hashes.memory.cap + _sl_rv.scratch.memory.cap + " + " + ".join(f"SAY_ARRAY_BYTES(_sl_rv.{name})" for name in work_arrays)
    def instrument_workspace(match):
        function = match[0]
        return function.replace("return _sl_rv;", "atomic_store(&say_workspace_storage, " + work_size + ");\n return _sl_rv;")
    source, count = re.subn(r"static sl_st_domain_Workspace sl_domain_new_workspace\([^;]*?\) \{.*?\n\}", instrument_workspace, source, count=1, flags=re.S)
    if count != 1:
        raise RuntimeError("workspace constructor symbol changed")
    instrumented = target.with_suffix(".instrumented.c")
    instrumented.write_text(PREFIX + source + SUFFIX)
    subprocess.run(["cc", "-O3", "-flto=auto", "-fwrapv", str(instrumented), "-o", str(target), "-lpthread"], check=True)


if __name__ == "__main__":
    main()
