//! Implements allocation routines used by the generated code and the GC.

use core::arch::wasm32;

use crate::gc;
use crate::rts_trap_with;
use crate::types::{skew, Bytes, SkewedPtr, Words};

#[no_mangle]
unsafe extern "C" fn alloc_bytes(n: Bytes<u32>) -> SkewedPtr {
    alloc_words(n.to_words())
}

#[no_mangle]
unsafe extern "C" fn alloc_words(n: Words<u32>) -> SkewedPtr {
    let bytes = n.to_bytes();
    // Update ALLOCATED
    gc::ALLOCATED += Bytes(bytes.0 as u64);

    // Update heap pointer
    let old_hp = gc::HP;
    let new_hp = old_hp + bytes.0;
    gc::HP = new_hp;

    // Grow memory if needed
    grow_memory(new_hp as usize);

    skew(old_hp as usize)
}

/// Page allocation. Ensures that the memory up to the given pointer is allocated.
pub(crate) unsafe fn grow_memory(ptr: usize) {
    let total_pages_needed = ((ptr / 65536) + 1) as i32;
    let current_pages = wasm32::memory_size(0) as i32;
    let new_pages_needed = total_pages_needed - current_pages;
    if new_pages_needed > 0 {
        if wasm32::memory_grow(0, new_pages_needed as usize) == core::usize::MAX {
            rts_trap_with("Cannot grow memory\0".as_ptr());
        }
    }
}
