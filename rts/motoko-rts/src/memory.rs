#[cfg(feature = "ic")]
pub mod ic;

use crate::constants::WASM_HEAP_SIZE;
use crate::rts_trap_with;
use crate::types::*;

use motoko_rts_macros::ic_mem_fn;

/// A trait for heap allocation. RTS functions allocate in heap via this trait.
///
/// To be able to link the RTS with moc-generated code, we implement wrappers around allocating
/// functions that pass `ic::IcMemory` for the `Memory` arguments, and export these functions with
/// the expected names for the generated code. For example, for a function like
///
/// ```
/// unsafe fn allocating_function<M: Memory>(mem: &mut M) { ... }
/// ```
///
/// we implement (or generate with a macro)
///
/// ```
/// #[no_mangle]
/// unsafe extern "C" fn export_name() { allocating_function(crate::memory::ic::IcMemory) }
/// ```
///
/// This function does not take any `Memory` arguments can be used by the generated code.
pub trait Memory {
    unsafe fn alloc_words(&mut self, n: Words<u32>) -> Value;
}

/// Allocate a new blob for the mutator with the default incremental mark allocation scheme.
#[ic_mem_fn]
pub unsafe fn alloc_blob<M: Memory>(mem: &mut M, size: Bytes<u32>) -> Value {
    let ptr = mem.alloc_words(size_of::<Blob>() + size.to_words());
    // NB. Cannot use `as_blob` here as we didn't write the header yet
    let blob = ptr.get_ptr() as *mut Blob;
    blob.initialize_tag(TAG_BLOB);
    (*blob).header.forward = ptr;
    (*blob).len = size;

    ptr
}

/// RTS-internal allocation of blobs for the GC that can be collected during the next GC run.
pub(crate) unsafe fn alloc_collectable_blob<M: Memory>(mem: &mut M, size: Bytes<u32>) -> Value {
    let ptr = mem.alloc_words(size_of::<Blob>() + size.to_words());
    let blob = ptr.get_ptr() as *mut Blob;
    (*blob).header.raw_tag = TAG_BLOB;
    (*blob).header.forward = ptr;
    (*blob).len = size;
    debug_assert!(!(blob as *mut Obj).is_marked());
    ptr
}

/// Allocate an array for the mutator with the default incremental mark allocation scheme.
#[ic_mem_fn]
pub unsafe fn alloc_array<M: Memory>(mem: &mut M, len: u32) -> Value {
    // Array payload should not be larger than half of the memory
    if len > (WASM_HEAP_SIZE / 2).0 {
        rts_trap_with("Array allocation too large");
    }

    let skewed_ptr = mem.alloc_words(size_of::<Array>() + Words(len));

    let ptr: *mut Array = skewed_ptr.get_ptr() as *mut Array;
    ptr.initialize_tag(TAG_ARRAY);
    (*ptr).header.forward = skewed_ptr;
    (*ptr).len = len;

    skewed_ptr
}
