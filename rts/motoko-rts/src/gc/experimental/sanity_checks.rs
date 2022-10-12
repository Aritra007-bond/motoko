//! Extensive sanity checks for experimental GC features.
//! * Write barrier coverage by memory snapshot comparisons.
#![allow(dead_code)]

use core::ptr::null_mut;

use super::write_barrier::REMEMBERED_SET;
use crate::mem_utils::memcpy_bytes;
use crate::memory::{alloc_blob, Memory};
use crate::types::*;
use crate::visitor::visit_pointer_fields;

static mut SNAPSHOT: *mut Blob = null_mut();

/// Take a memory snapshot. To be initiated after GC run.
pub unsafe fn take_snapshot<M: Memory>(mem: &mut M, hp: u32) {
    let length = Bytes(hp);
    let blob = alloc_blob(mem, length).get_ptr() as *mut Blob;
    memcpy_bytes(blob.payload_addr() as usize, 0, length);
    SNAPSHOT = blob;
}

/// Verify write barrier coverag by comparing the memory against the previous snapshot.
/// To be initiated before the next GC run. No effect if no snapshpot has been taken.
pub unsafe fn verify_snapshot(
    heap_base: u32,
    last_free: u32,
    hp: u32,
    static_roots: Value,
    verify_roots: bool,
) {
    assert!(heap_base <= hp);
    if verify_roots {
        verify_static_roots(static_roots.as_array(), last_free as usize);
    }
    verify_heap(heap_base as usize, last_free as usize, hp as usize);
}

unsafe fn verify_static_roots(static_roots: *mut Array, last_free: usize) {
    for index in 0..static_roots.len() {
        let current = static_roots.get(index).as_obj();
        assert_eq!(current.tag(), TAG_MUTBOX); // check tag
        let mutbox = current as *mut MutBox;
        let current_field = &mut (*mutbox).field;
        if relevant_field(current_field, last_free) {
            verify_field(current_field);
        }
    }
}

unsafe fn verify_heap(base: usize, last_free: usize, limit: usize) {
    if SNAPSHOT.is_null() {
        return;
    }
    println!(100, "Heap verification starts...");
    assert!(SNAPSHOT.len().as_usize() <= limit);
    let mut pointer = base;
    while pointer < SNAPSHOT.len().as_usize() {
        let current = pointer as *mut Obj;
        let previous = (SNAPSHOT.payload_addr() as usize + pointer) as *mut Obj;
        assert!(current.tag() == previous.tag());
        visit_pointer_fields(
            &mut (),
            current,
            current.tag(),
            0,
            |_, current_field| {
                if relevant_field(current_field, last_free) {
                    verify_field(current_field);
                }
            },
            |_, slice_start, arr| {
                assert!(slice_start == 0);
                arr.len()
            },
        );
        pointer += object_size(current as usize).to_bytes().as_usize();
    }
    println!(100, "Heap verification stops...");
}

unsafe fn relevant_field(current_field: *mut Value, last_free: usize) -> bool {
    if (current_field as usize) < last_free {
        let value = *current_field;
        value.is_ptr() && value.get_raw() as usize >= last_free
    } else {
        false
    }
}

unsafe fn verify_field(current_field: *mut Value) {
    let memory_copy = SNAPSHOT.payload_addr() as usize;
    let previous_field = (memory_copy + current_field as usize) as *mut Value;
    if *previous_field != *current_field && !recorded(current_field as u32) {
        panic!("Missing write barrier at {:#x}", current_field as usize);
    }
}

unsafe fn recorded(value: u32) -> bool {
    match &REMEMBERED_SET {
        None => panic!("No remembered set"),
        Some(remembered_set) => {
            let mut iterator = remembered_set.iterate();
            while iterator.has_next() {
                if iterator.current().get_raw() == value {
                    return true;
                }
                iterator.next();
            }
            false
        }
    }
}
