use crate::mem_utils::memcpy_words;
use crate::space::Space;
use crate::types::*;

#[cfg(feature = "ic")]
#[no_mangle]
unsafe fn schedule_copying_gc() {
    if super::should_do_gc() {
        copying_gc();
    }
}

#[cfg(feature = "ic")]
#[no_mangle]
unsafe fn copying_gc() {
    use crate::memory::ic;

    let mut to_space = Space::new();

    copying_gc_internal(
        &mut to_space,
        ic::get_heap_base(),
        ic::get_static_roots(),
        crate::continuation_table::continuation_table_loc(),
        // note_live_size
        |live_size| ic::MAX_LIVE = ::core::cmp::max(ic::MAX_LIVE, live_size),
        // note_reclaimed
        |reclaimed| ic::RECLAIMED += Bytes(reclaimed.0 as u64),
    );

    ic::LAST_HP = ic::HP;

    crate::allocation_space::free_and_update_allocation_space(to_space);
}

// TODO: Update stats
pub unsafe fn copying_gc_internal<NoteLiveSize: Fn(Bytes<u32>), NoteReclaimed: Fn(Bytes<u32>)>(
    to_space: &mut Space,
    heap_base: u32,
    static_roots: SkewedPtr,
    continuation_table_loc: *mut SkewedPtr,
    _note_live_size: NoteLiveSize,
    _note_reclaimed: NoteReclaimed,
) {
    let heap_base = heap_base as usize;

    let static_roots = static_roots.as_array();

    // Evacuate roots
    evac_static_roots(heap_base, to_space, static_roots);

    if (*continuation_table_loc).unskew() >= heap_base {
        evac(to_space, continuation_table_loc as usize);
    }

    // Scavenge to-space
    let mut to_space_page = Some(to_space.first_page());
    while let Some(page) = to_space_page {
        let mut p = page.start();

        let page_end = page.end();

        while p < page_end {
            let size = object_size(p);
            scav(heap_base, to_space, p);
            p += size.to_bytes().0 as usize;
        }

        to_space_page = page.next();
    }
}

/// Evacuate (copy) an object in from-space to to-space.
unsafe fn evac(to_space: &mut Space, ptr_loc: usize) {
    // Field holds a skewed pointer to the object to evacuate
    let ptr_loc = ptr_loc as *mut SkewedPtr;

    let obj = (*ptr_loc).unskew() as *mut Obj;

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
    let obj_addr = to_space.alloc_words(obj_size).unskew() as usize;

    // Copy object to to-space
    memcpy_words(obj_addr, obj as usize, obj_size);

    // Set forwarding pointer
    let fwd = obj as *mut FwdPtr;
    (*fwd).header.tag = TAG_FWD_PTR;
    (*fwd).fwd = skew(obj_addr);

    // Update evacuated field
    *ptr_loc = skew(obj_addr);
}

unsafe fn scav(heap_base: usize, to_space: &mut Space, obj: usize) {
    let obj = obj as *mut Obj;

    crate::visitor::visit_pointer_fields(obj, obj.tag(), heap_base, |field_addr| {
        evac(to_space, field_addr as usize);
    });
}

// We have a special evacuation routine for "static roots" array: we don't evacuate elements of
// "static roots", we just scavenge them.
unsafe fn evac_static_roots(heap_base: usize, to_space: &mut Space, roots: *mut Array) {
    // The array and the objects pointed by the array are all static so we don't evacuate them. We
    // only evacuate fields of objects in the array.
    for i in 0..roots.len() {
        let obj = roots.get(i);
        scav(heap_base, to_space, obj.unskew());
    }
}
