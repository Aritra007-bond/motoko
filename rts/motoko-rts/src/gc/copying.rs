use crate::constants::WORD_SIZE;
use crate::mem_utils::memcpy_words;
use crate::page_alloc::{Page, PageAlloc};
use crate::space::Space;
use crate::types::*;

#[cfg(feature = "ic")]
#[no_mangle]
unsafe fn schedule_copying_gc() {
    if super::should_do_gc(crate::allocation_space::ALLOCATION_SPACE.as_ref().unwrap()) {
        copying_gc();
    }
}

#[cfg(feature = "ic")]
#[no_mangle]
unsafe fn copying_gc() {
    let mut to_space = Space::new(crate::page_alloc::ic::IcPageAlloc {});

    copying_gc_internal(
        &mut to_space,
        crate::get_static_roots(),
        crate::continuation_table::continuation_table_loc(),
        // note_live_size
        |_live_size| {}, // TODO
        // note_reclaimed
        |_reclaimed| {}, // TODO
    );

    crate::allocation_space::free_and_update_allocation_space(to_space);
}

// TODO: Update stats
pub unsafe fn copying_gc_internal<
    P: PageAlloc,
    NoteLiveSize: Fn(Bytes<u32>),
    NoteReclaimed: Fn(Bytes<u32>),
>(
    to_space: &mut Space<P>,
    static_roots: Value,
    continuation_table_loc: *mut Value,
    _note_live_size: NoteLiveSize,
    _note_reclaimed: NoteReclaimed,
) {
    let static_roots = static_roots.as_array();

    // Evacuate roots
    evac_static_roots(to_space, static_roots);

    if (*continuation_table_loc).is_ptr() {
        evac(to_space, continuation_table_loc as usize);
    }

    // Scavenge to-space
    let mut to_space_page_idx = to_space.first_page();
    while let Some(page) = to_space.get_page(to_space_page_idx) {
        let mut p = page.contents_start();

        let page_end = page.end();

        while p != to_space.allocation_pointer() && p != page_end {
            let size = object_size(p);
            scav(to_space, p);
            p += size.to_bytes().0 as usize;
        }

        to_space_page_idx = to_space_page_idx.next();
    }
}

/// Evacuate (copy) an object in from-space to to-space.
unsafe fn evac<P: PageAlloc>(to_space: &mut Space<P>, ptr_loc: usize) {
    // Field holds a skewed pointer to the object to evacuate
    let ptr_loc = ptr_loc as *mut Value;

    let obj = (*ptr_loc).as_obj();

    // Check object alignment to avoid undefined behavior. See also static_checks module.
    debug_assert_eq!(obj as u32 % WORD_SIZE, 0);

    if obj.is_large() {
        return evac_large(obj);
    }

    let tag = obj.tag();

    // Update the field if the object is already evacauted
    if tag == TAG_FWD_PTR {
        let fwd = (*(obj as *const FwdPtr)).fwd;
        *ptr_loc = fwd;
        return;
    } else if tag == TAG_ONE_WORD_FILLER || tag == TAG_FREE_SPACE {
        return;
    }

    let obj_size = object_size(obj as usize);

    // Allocate space in to-space for the object
    let obj_addr = to_space.alloc_words(obj_size).get_ptr();

    // Copy object to to-space
    memcpy_words(obj_addr, obj as usize, obj_size);

    // Set forwarding pointer
    let fwd = obj as *mut FwdPtr;
    fwd.set_tag();
    fwd.set_forwarding(obj_addr);

    // Update evacuated field
    *ptr_loc = Value::from_ptr(obj_addr);
}

unsafe fn evac_large(_obj: *mut Obj) {
    todo!("evac_large");
}

unsafe fn scav<P: PageAlloc>(to_space: &mut Space<P>, obj: usize) {
    let obj = obj as *mut Obj;

    crate::visitor::visit_pointer_fields(obj, obj.tag(), |field_addr| {
        evac(to_space, field_addr as usize);
    });
}

// We have a special evacuation routine for "static roots" array: we don't evacuate elements of
// "static roots", we just scavenge them.
unsafe fn evac_static_roots<P: PageAlloc>(to_space: &mut Space<P>, roots: *mut Array) {
    // The array and the objects pointed by the array are all static so we don't evacuate them. We
    // only evacuate fields of objects in the array.
    for i in 0..roots.len() {
        let obj = roots.get(i);
        scav(to_space, obj.get_ptr());
    }
}
