//! Global allocator: small blocks go to mimalloc; blocks of 1 MiB
//! and up are mapped directly and unmapped on free.
//!
//! Search results for broad queries allocate tens of MB of temporary vectors.
//! macOS malloc keeps such freed large blocks resident ("Malloc Large (empty)"),
//! which showed up as hundreds of MB of footprint after a few broad searches.
//! Unmapping returns them to the OS immediately.
//! Full walks also create millions of short-lived small names and tree nodes.
//! Keeping those on macOS malloc interleaves them with the surviving index and
//! retains hundreds of MB of fragmented pages after the walk. mimalloc owns
//! only Rust's small blocks; Swift/framework allocations retain their allocator.

use mimalloc::MiMalloc;
use std::{
    alloc::{GlobalAlloc, Layout},
    ffi::c_void,
    ptr,
};

const DIRECT_MIN: usize = 1 << 20;
const PAGE: usize = 16 * 1024;

const PROT_READ: i32 = 1;
const PROT_WRITE: i32 = 2;
const MAP_PRIVATE: i32 = 0x0002;
const MAP_ANON: i32 = 0x1000;

unsafe extern "C" {
    fn mmap(addr: *mut c_void, len: usize, prot: i32, flags: i32, fd: i32, offset: i64) -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> i32;
}

pub struct SiftAlloc;

unsafe extern "C" {
    fn mi_collect(force: bool);
}

/// Called only after a large allocation phase has dropped its temporary data.
/// This visits the caller's heap and purges unused process-wide arena pages;
/// live index allocations are retained. No timer or per-event collection.
pub(crate) fn collect_unused() {
    unsafe { mi_collect(true) };
}

pub(crate) struct CollectOnDrop;
impl Drop for CollectOnDrop {
    fn drop(&mut self) { collect_unused(); }
}

#[inline]
fn direct(layout: &Layout) -> bool {
    layout.size() >= DIRECT_MIN && layout.align() <= PAGE
}

#[inline]
fn round_up(size: usize) -> usize {
    (size + PAGE - 1) & !(PAGE - 1)
}

unsafe fn map(size: usize) -> *mut u8 {
    let p = unsafe {
        mmap(ptr::null_mut(), round_up(size), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
    };
    if p as isize == -1 { ptr::null_mut() } else { p.cast() }
}

unsafe impl GlobalAlloc for SiftAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if direct(&layout) { unsafe { map(layout.size()) } } else { unsafe { MiMalloc.alloc(layout) } }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        // Fresh anonymous mappings are already zeroed.
        if direct(&layout) { unsafe { map(layout.size()) } } else { unsafe { MiMalloc.alloc_zeroed(layout) } }
    }

    unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
        if direct(&layout) {
            unsafe { munmap(p.cast(), round_up(layout.size())) };
        } else {
            unsafe { MiMalloc.dealloc(p, layout) }
        }
    }

    unsafe fn realloc(&self, p: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let new_layout = unsafe { Layout::from_size_align_unchecked(new_size, layout.align()) };
        match (direct(&layout), direct(&new_layout)) {
            (false, false) => unsafe { MiMalloc.realloc(p, layout, new_size) },
            (true, true) if round_up(new_size) == round_up(layout.size()) => p,
            (true, true) if round_up(new_size) < round_up(layout.size()) => {
                // Shrink in place by unmapping the tail pages.
                let keep = round_up(new_size);
                unsafe { munmap(p.add(keep).cast(), round_up(layout.size()) - keep) };
                p
            }
            _ => {
                let q = unsafe { self.alloc(new_layout) };
                if !q.is_null() {
                    unsafe {
                        ptr::copy_nonoverlapping(p, q, layout.size().min(new_size));
                        self.dealloc(p, layout);
                    }
                }
                q
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocations_preserve_alignment_and_bytes_across_allocator_boundaries() {
        for align in [8, 4096, 32768] {
            unsafe {
                let small = Layout::from_size_align(8192, align).unwrap();
                let original = SiftAlloc.alloc(small);
                assert!(!original.is_null());
                assert_eq!(original as usize % align, 0);
                for i in 0..small.size() { original.add(i).write((i % 251) as u8); }
                let large_size = 2 * DIRECT_MIN + 37;
                let large = SiftAlloc.realloc(original, small, large_size);
                assert!(!large.is_null());
                assert_eq!(large as usize % align, 0);
                for i in 0..small.size() { assert_eq!(large.add(i).read(), (i % 251) as u8); }
                let layout = Layout::from_size_align(large_size, align).unwrap();
                let shrunk = SiftAlloc.realloc(large, layout, 4096);
                assert!(!shrunk.is_null());
                assert_eq!(shrunk as usize % align, 0);
                for i in 0..4096 { assert_eq!(shrunk.add(i).read(), (i % 251) as u8); }
                SiftAlloc.dealloc(shrunk, Layout::from_size_align(4096, align).unwrap());
            }
        }
    }

    #[test]
    fn small_blocks_allocated_on_worker_remain_valid_until_freed_on_caller() {
        let blocks = std::thread::spawn(|| (0..20_000usize)
            .map(|i| vec![(i % 251) as u8; 24 + i % 1024]).collect::<Vec<_>>()).join().unwrap();
        for (i, block) in blocks.iter().enumerate() {
            assert!(block.iter().all(|&byte| byte == (i % 251) as u8));
        }
        drop(blocks);
    }

    #[test]
    fn large_vectors_grow_shrink_and_free() {
        let mut v: Vec<u64> = Vec::new();
        for i in 0..2_000_000u64 {
            v.push(i);
        }
        assert_eq!(v.iter().sum::<u64>(), 1_999_999 * 2_000_000 / 2);
        v.truncate(300_000);
        v.shrink_to_fit(); // direct → direct shrink
        assert_eq!(v[299_999], 299_999);
        v.truncate(10);
        v.shrink_to_fit(); // direct → system
        assert_eq!(v, (0..10).collect::<Vec<_>>());
        let z = vec![0u8; 3 << 20]; // alloc_zeroed path
        assert!(z.iter().all(|&b| b == 0));
    }
}
