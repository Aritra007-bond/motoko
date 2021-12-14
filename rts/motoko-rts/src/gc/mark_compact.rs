//! Implements threaded compaction as described in "High-Performance Garbage Collection for
//! Memory-Constrained Environments" section 5.1.2, which is an improved version of the original
//! threaded compaction algorithm described in The Garbage Collection Handbook section 3.3.

pub mod mark_stack;

use crate::bitmap::{Bitmap, BITMAP_ITER_END};
use crate::constants::WORD_SIZE;
use crate::mem_utils::memcpy_words;
use crate::page_alloc::{Page, PageAlloc, PageHeader};
use crate::space::Space;
use crate::types::*;
use crate::visitor::visit_pointer_fields;
use mark_stack::MarkStack;

#[cfg(feature = "ic")]
#[no_mangle]
unsafe fn schedule_compacting_gc() {
    // 512 MiB slack for mark stack + allocation area for the next message
    let slack: u64 = 512 * 1024 * 1024;
    let heap_size_bytes: u64 =
        u64::from(crate::constants::WASM_HEAP_SIZE.as_u32()) * u64::from(WORD_SIZE);
    // Larger than necessary to keep things simple
    let max_bitmap_size_bytes = heap_size_bytes / 32;
    // NB. `max_live` is evaluated in compile time to a constant
    let max_live: Bytes<u64> = Bytes(heap_size_bytes - slack - max_bitmap_size_bytes);

    if super::should_do_gc(
        crate::allocation_space::ALLOCATION_SPACE.assume_init_ref(),
        max_live,
    ) {
        compacting_gc();
    }
}

#[cfg(feature = "ic")]
#[no_mangle]
unsafe fn compacting_gc() {
    compacting_gc_internal(
        &crate::page_alloc::ic::IcPageAlloc {},
        crate::allocation_space::ALLOCATION_SPACE.assume_init_mut(),
        crate::get_static_roots(),
        crate::continuation_table::continuation_table_loc(),
        // note_live_size
        |_live_size| {}, // TODO
        // note_reclaimed
        |_reclaimed| {}, // TODO
    );
}

pub unsafe fn compacting_gc_internal<
    P: PageAlloc,
    NoteLiveSize: Fn(Bytes<u32>),
    NoteReclaimed: Fn(Bytes<u32>),
>(
    page_alloc: &P,
    space: &mut Space<P>,
    static_roots: Value,
    continuation_table_ptr_loc: *mut Value,
    _note_live_size: NoteLiveSize,
    _note_reclaimed: NoteReclaimed,
) {
    mark_compact(page_alloc, space, static_roots, continuation_table_ptr_loc);

    // TODO: Update stats
}

unsafe fn mark_compact<P: PageAlloc>(
    page_alloc: &P,
    space: &mut Space<P>,
    static_roots: Value,
    continuation_table_ptr_loc: *mut Value,
) {
    // Allocate bitmaps
    for page in space.iter_pages() {
        let page_size = Bytes(page.size() as u32).to_words();
        page.set_bitmap(Some(Bitmap::new(page_size.0)));
    }

    let mut stack = MarkStack::new(page_alloc.clone());

    mark_static_roots(space, &mut stack, static_roots);

    if (*continuation_table_ptr_loc).is_ptr() {
        // TODO: No need to check if continuation table is already marked
        mark_object(space, &mut stack, *continuation_table_ptr_loc);
        // Similar to `mark_root_mutbox_fields`, `continuation_table_ptr_loc` is in static heap so it
        // will be readable when we unthread continuation table
        thread(continuation_table_ptr_loc);
    }

    mark_stack(space, &mut stack);

    update_refs(space);

    stack.free();

    // Free bitmaps
    for page in space.iter_pages() {
        let bitmap = page.take_bitmap().unwrap();
        bitmap.free();
    }
}

unsafe fn mark_static_roots<P: PageAlloc>(
    space: &Space<P>,
    mark_stack: &mut MarkStack<P>,
    static_roots: Value,
) {
    let root_array = static_roots.as_array();

    // Static objects are not in the dynamic heap so don't need marking.
    for i in 0..root_array.len() {
        let obj = root_array.get(i).as_obj();
        // Root array should only has pointers to other static MutBoxes
        debug_assert_eq!(obj.tag(), TAG_MUTBOX);
        debug_assert!(obj.is_static());
        mark_root_mutbox_fields(space, mark_stack, obj as *mut MutBox);
    }
}

/// Specialized version of `mark_fields` for root `MutBox`es.
unsafe fn mark_root_mutbox_fields<P: PageAlloc>(
    space: &Space<P>,
    mark_stack: &mut MarkStack<P>,
    mutbox: *mut MutBox,
) {
    let field_addr = &mut (*mutbox).field;
    // TODO: Not sure if this check is necessary?
    if (*field_addr).is_ptr_to_dynamic_heap() {
        // TODO: We should be able to omit the "already marked" check here as no two root MutBox
        // can point to the same object (I think)
        mark_object(space, mark_stack, *field_addr);
        // It's OK to thread forward pointers here as the static objects won't be moved, so we will
        // be able to unthread objects pointed by these fields later.
        thread(field_addr);
    }
}

unsafe fn mark_object<P: PageAlloc>(space: &Space<P>, mark_stack: &mut MarkStack<P>, obj: Value) {
    let obj_tag = obj.tag();
    let obj = obj.get_ptr();

    // Check object alignment to avoid undefined behavior. See also static_checks module.
    debug_assert_eq!(obj as u32 % WORD_SIZE, 0);

    let obj_page = space.page_alloc().get_address_page_start(obj) as *mut PageHeader;
    let obj_bitmap = obj_page.get_bitmap().unwrap();
    let obj_page_offset = obj - (obj_page.add(1) as usize);

    let obj_bit_idx = obj_page_offset as u32 / WORD_SIZE;

    if obj_bitmap.get(obj_bit_idx) {
        // Already marked
        return;
    }

    obj_bitmap.set(obj_bit_idx);

    mark_stack.push(obj, obj_tag);
}

unsafe fn mark_stack<P: PageAlloc>(space: &Space<P>, mark_stack: &mut MarkStack<P>) {
    while let Some((obj, tag)) = mark_stack.pop() {
        mark_fields(space, mark_stack, obj as *mut Obj, tag);
    }
}

unsafe fn mark_fields<P: PageAlloc>(
    space: &Space<P>,
    mark_stack: &mut MarkStack<P>,
    obj: *mut Obj,
    obj_tag: Tag,
) {
    visit_pointer_fields(obj, obj_tag, |field_addr| {
        let field_value = *field_addr;
        mark_object(space, mark_stack, field_value);

        // Thread if backwards or self pointer
        if field_value.get_ptr() <= obj as usize {
            thread(field_addr);
        }
    });
}

/// Linearly scan the heap, for each live object:
///
/// - Mark step threads all backwards pointers and pointers from roots, so unthread to update those
///   pointers to the objects new location.
///
/// - Move the object
///
/// - Thread forward pointers of the object
///
unsafe fn update_refs<P: PageAlloc>(space: &mut Space<P>) {
    let pages = space.sorted_pages();

    // Next object will be moved to this page
    let mut to_page_idx = 0;

    // TODO: Update rustc, use unwrap_unchecked
    let mut to_page = &pages[to_page_idx];

    // Next object will be moved to this address in `to_page`
    let mut to_addr = to_page.contents_start();

    for page in &pages {
        let page_start = page.contents_start();

        let bitmap = page.get_bitmap().unwrap();
        let mut bitmap_iter = bitmap.iter();
        let mut bit = bitmap_iter.next();

        while bit != BITMAP_ITER_END {
            let p = (page_start + (bit * WORD_SIZE) as usize) as *mut Obj;

            // Get the object header first, to be able to check whether it will fit the current page or we
            // need to move on to the next page
            // TODO: Use two bits for object, use bitmap to get object size, remove get_tag
            let obj_tag = get_tag(p);
            let obj_size = object_size_(p as usize, obj_tag);

            if to_addr + obj_size.to_bytes().as_usize() > to_page.end() {
                // Object does not fit into the current page, move on to the next page
                // We know there must be more pages in the space as we compact the space and don't
                // allocate in it
                to_page_idx += 1;
                to_page = &pages[to_page_idx];
                to_addr = to_page.contents_start();
            }

            // Update backwards references to the object's new location and restore object header
            unthread(p, to_addr as u32);

            // Move the object
            if to_addr != p as usize {
                memcpy_words(to_addr, p as usize, obj_size);
            }

            // Thread forward pointers of the object
            thread_fwd_pointers(to_addr as *mut Obj);

            to_addr += obj_size.to_bytes().as_usize();

            bit = bitmap_iter.next();
        }
    }

    space.set_pages(pages, to_addr);
}

/// Thread forwards pointers in object
unsafe fn thread_fwd_pointers(obj: *mut Obj) {
    visit_pointer_fields(obj, obj.tag(), |field_addr| {
        if (*field_addr).get_ptr() > obj as usize {
            thread(field_addr)
        }
    });
}

/// Thread a pointer field
unsafe fn thread(field: *mut Value) {
    // Store pointed object's header in the field, field address in the pointed object's header
    let pointed = (*field).as_obj();
    let pointed_header = pointed.as_word();
    *field = Value::from_raw(pointed_header);
    pointed.set_header_word(field as u32);
}

/// Unthread all references at given header, replacing with `new_loc`. Restores object header.
unsafe fn unthread(obj: *mut Obj, new_loc: u32) {
    let mut header = obj.as_word();

    // All objects and fields are word-aligned, and tags have the lowest bit set, so use the lowest
    // bit to distinguish a header (tag) from a field address.
    while header & 0b1 == 0 {
        let tmp = (header as *mut Obj).as_word();
        *(header as *mut Value) = Value::from_ptr(new_loc as usize);
        header = tmp;
    }

    obj.set_header_word(header);
}

/// Follow a chain, return object header. Does not unthread.
unsafe fn get_tag(obj: *mut Obj) -> Tag {
    let mut header = obj.as_word();
    while header & 0b1 == 0 {
        header = (header as *mut Obj).as_word();
    }
    // At the end of the chain is the original header for the object
    let header = Obj::from_header_word(header);
    debug_assert!(
        header.tag >= TAG_OBJECT && header.tag <= TAG_NULL,
        "{}",
        header.tag
    );
    header.tag
}
