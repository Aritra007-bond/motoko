use crate::alloc::alloc_words;
use crate::types::{size_of, Array, Bytes, SkewedPtr, Words, TAG_ARRAY};

const ITER_BLOB_IDX: u32 = 0;
const ITER_POS_IDX: u32 = 1;

/// Returns iterator for the given blob
#[no_mangle]
unsafe extern "C" fn blob_iter(blob: SkewedPtr) -> SkewedPtr {
    let iter_ptr = alloc_words(size_of::<Array>() + Words(2));

    let iter_array = iter_ptr.unskew() as *mut Array;
    (*iter_array).header.tag = TAG_ARRAY;
    (*iter_array).len = 2;

    iter_array.set(ITER_BLOB_IDX, blob);
    iter_array.set(ITER_POS_IDX, SkewedPtr(0));

    iter_ptr
}

/// Returns whether the iterator is finished
#[no_mangle]
unsafe extern "C" fn blob_iter_done(iter: SkewedPtr) -> u32 {
    let iter_array = iter.as_array();

    let blob = iter_array.get(ITER_BLOB_IDX);
    let pos = Bytes((iter_array.get(ITER_POS_IDX).0 >> 2) as u32);

    (pos >= blob.as_blob().len()).into()
}

/// Reads next byte, advances the iterator
#[no_mangle]
unsafe extern "C" fn blob_iter_next(iter: SkewedPtr) -> u32 {
    let iter_array = iter.as_array();

    let blob = iter_array.get(ITER_BLOB_IDX);
    let pos = (iter_array.get(ITER_POS_IDX).0 >> 2) as u32;

    iter_array.set(ITER_POS_IDX, SkewedPtr(((pos + 1) << 2) as usize));

    blob.as_blob().get(pos).into()
}
