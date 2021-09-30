use crate::page_alloc::PageAlloc;
use crate::space::Space;
use crate::types::{size_of, Array, Bytes, Value, Words};

use motoko_rts_macros::ic_mem_fn;

const ITER_BLOB_IDX: u32 = 0;

const ITER_POS_IDX: u32 = 1;

/// Returns iterator for the given blob
#[ic_mem_fn]
unsafe fn blob_iter<P: PageAlloc>(allocation_space: &mut Space<P>, blob: Value) -> Value {
    let iter_ptr = allocation_space.alloc_words(size_of::<Array>() + Words(2));

    // NB. cannot use as_array() here as we didn't write the header yet
    let iter_array = iter_ptr.get_ptr() as *mut Array;
    iter_array.set_tag();
    iter_array.set_len(2);

    iter_array.set(ITER_BLOB_IDX, blob);
    iter_array.set(ITER_POS_IDX, Value::from_scalar(0));

    iter_ptr
}

/// Returns whether the iterator is finished
#[no_mangle]
unsafe extern "C" fn blob_iter_done(iter: Value) -> u32 {
    let iter_array = iter.as_array();

    let blob = iter_array.get(ITER_BLOB_IDX);
    let pos = Bytes(iter_array.get(ITER_POS_IDX).get_scalar());

    (pos >= blob.as_blob().len()).into()
}

/// Reads next byte, advances the iterator
#[no_mangle]
unsafe extern "C" fn blob_iter_next(iter: Value) -> u32 {
    let iter_array = iter.as_array();

    let blob = iter_array.get(ITER_BLOB_IDX);
    let pos = iter_array.get(ITER_POS_IDX).get_scalar();

    iter_array.set(ITER_POS_IDX, Value::from_scalar(pos + 1));

    blob.as_blob().get(pos).into()
}
