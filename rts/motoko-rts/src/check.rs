use crate::{
    constants::WORD_SIZE,
    types::*,
    visitor::{pointer_to_dynamic_heap, visit_pointer_fields},
};

use motoko_rts_macros::ic_mem_fn;

pub struct MemoryChecker {
    heap_base: usize,
    heap_end: usize,
    static_roots: Value,
    continuation_table_ptr_loc: *mut Value,
}

#[ic_mem_fn(ic_only)]
unsafe fn check_array_pointer<M: crate::memory::Memory>(
    _mem: &mut M,
    array: Value,
    pointer: Value,
) {
    assert!(array.is_ptr());
    assert!(pointer.is_ptr());
    let array = array.as_array();
    //println!(100, "Array length: {}", array.len());
    let pointer = pointer.get_ptr() as u32;
    // println!(
    //     100,
    //     "Array access {:#x} in {:#x} [{:#x} .. {:#x}]",
    //     pointer,
    //     array as usize,
    //     array.payload_addr() as usize,
    //     array.payload_addr() as u32 + array.len() * WORD_SIZE
    // );
    assert!(pointer >= array.payload_addr() as u32);
    assert!(pointer + WORD_SIZE as u32 <= array.payload_addr() as u32 + array.len() * WORD_SIZE);
}

#[ic_mem_fn(ic_only)]
unsafe fn check_memory<M: crate::memory::Memory>(_mem: &mut M) {
    use crate::memory::ic;
    let heap_base = if ic::ALIGN {
        ic::get_aligned_heap_base()
    } else {
        ic::get_heap_base()
    };
    let checker = MemoryChecker {
        heap_base: heap_base as usize,
        heap_end: ic::HP as usize,
        static_roots: ic::get_static_roots(),
        continuation_table_ptr_loc: crate::continuation_table::continuation_table_loc(),
    };
    checker.check_memory();
}

impl MemoryChecker {
    pub unsafe fn check_memory(&self) {
        // println!(100, "Memory check starts...");
        // println!(100, " Checking static roots...");
        self.check_static_roots();
        if (*self.continuation_table_ptr_loc).is_ptr() {
            // println!(100, " Checking continuation table...");
            self.check_object(*self.continuation_table_ptr_loc);
        }
        // println!(100, " Checking heap...");
        self.check_heap();
        // println!(100, "Memory check stops...");
    }

    unsafe fn check_static_roots(&self) {
        let root_array = self.static_roots.as_array();
        for i in 0..root_array.len() {
            let obj = root_array.get(i).as_obj();
            assert_eq!(obj.tag(), TAG_MUTBOX);
            assert!((obj as usize) < self.heap_base);
            let mutbox = obj as *mut MutBox;
            let field_addr = &mut (*mutbox).field;
            if pointer_to_dynamic_heap(field_addr, self.heap_base as usize) {
                let object = *field_addr;
                self.check_object(object);
            }
        }
    }

    unsafe fn check_object(&self, object: Value) {
        self.check_object_header(object);
        visit_pointer_fields(
            &mut (),
            object.as_obj(),
            object.tag(),
            0,
            |_, field_address| {
                if Self::is_ptr(*field_address) {
                    (&self).check_object_header(*field_address);
                }
            },
            |_, _, arr| arr.len(),
        );
    }

    unsafe fn check_object_header(&self, object: Value) {
        assert!(Self::is_ptr(object));
        let pointer = object.get_ptr();
        assert!(pointer < self.heap_end);
        let tag = object.tag();
        const COERCION_FAILURE: u32 = 0xfffffffe;
        assert!(tag >= TAG_OBJECT && tag <= TAG_NULL || tag == COERCION_FAILURE);
    }

    unsafe fn check_heap(&self) {
        let mut pointer = self.heap_base;
        while pointer < self.heap_end {
            let object = Value::from_ptr(pointer as usize);
            if (object.get_ptr() as *mut Obj).tag() != TAG_ONE_WORD_FILLER {
                self.check_object(object);
            }
            pointer += object_size(pointer as usize).to_bytes().as_usize();
        }
    }

    unsafe fn is_ptr(value: Value) -> bool {
        const TRUE_VALUE: u32 = 1;
        value.is_ptr() && value.get_raw() != TRUE_VALUE
    }
}
