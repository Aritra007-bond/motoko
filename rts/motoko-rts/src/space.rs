use crate::constants::WORD_SIZE;
use crate::page_alloc::{Page, PageAlloc};
use crate::rts_trap_with;
use crate::types::*;

use alloc::vec;
use alloc::vec::Vec;

/// A space is an allocation area, consists of a linked list of pages.
pub struct Space<P: PageAlloc> {
    /// Page allocator
    page_alloc: P,

    /// Pages in the space
    pages: Vec<P::Page>,

    /// Index of the current page
    current_page: usize,

    /// Allocation pointer in the current page
    hp: usize,

    /// Total amount allocated in this space so far. Note that when we allocate a new space because
    /// an allocation request is too much for the current space, rest of the current space will be
    /// accounted as allocated. (TODO: not sure about this part)
    total_alloc: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct PageIdx(usize);

impl PageIdx {
    pub fn next(self) -> Self {
        PageIdx(self.0 + 1)
    }
}

impl<P: PageAlloc> Space<P> {
    pub unsafe fn new(page_alloc: P) -> Space<P> {
        let current_page = page_alloc.alloc();
        let hp = current_page.contents_start();

        Space {
            page_alloc,
            pages: vec![current_page],
            current_page: 0,
            hp,
            total_alloc: 0,
        }
    }

    pub fn total_alloc(&self) -> usize {
        self.total_alloc
    }

    pub fn iter_pages(&self) -> impl Iterator<Item = &P::Page> {
        self.pages.iter()
    }

    fn current_page(&self) -> &P::Page {
        &self.pages[self.current_page]
    }

    pub fn first_page(&self) -> PageIdx {
        PageIdx(0)
    }

    pub fn last_page(&self) -> PageIdx {
        PageIdx(self.pages.len() - 1)
    }

    pub fn current_page_idx(&self) -> PageIdx {
        PageIdx(self.current_page)
    }

    pub fn get_page(&self, idx: PageIdx) -> Option<&P::Page> {
        self.pages.get(idx.0)
    }

    pub fn allocation_pointer(&self) -> usize {
        self.hp
    }

    pub unsafe fn alloc_words(&mut self, n: Words<u32>) -> Value {
        let bytes = n.to_bytes().as_usize();

        let current_page_end = self.current_page().end();

        if self.hp + bytes > current_page_end {
            let slop = current_page_end - self.hp;

            // Rest of the page is considered allocated
            self.total_alloc += slop;

            // In debug mode fill the slop with a filler object, to be able to check page sanity
            if cfg!(debug_assertions) {
                if slop == 1 {
                    *(self.hp as *mut u8) = TAG_ONE_WORD_FILLER;
                } else {
                    let free_space = self.hp as *mut FreeSpace;
                    (*free_space).header.tag = TAG_FREE_SPACE;
                    let slop = slop as u32;
                    assert_eq!(slop % WORD_SIZE, 0);
                    (*free_space).words = Bytes(slop).to_words();
                }
            }

            let new_page = self.page_alloc.alloc();

            self.hp = new_page.contents_start();
            self.pages.push(new_page);
            self.current_page += 1;
        }

        if self.hp + bytes > self.current_page().end() {
            todo!(
                "Large object allocation not implemented yet (requested size={} bytes, self.hp={:#x}, current page end={:#x})",
                n.to_bytes().as_u32(),
                self.hp,
                self.current_page().end(),
            );
        }

        let alloc = self.hp;

        self.hp += bytes;

        self.total_alloc += bytes;

        Value::from_ptr(alloc)
    }

    /// Free all pages of the space. The space itself should not be used afterwards.
    pub unsafe fn free(&mut self) {
        for page in self.pages.drain(..) {
            self.page_alloc.free(page);
        }
    }

    pub unsafe fn alloc_array(&mut self, len: u32) -> Value {
        // Array payload should not be larger than half of the memory
        if len > 1 << (32 - 2 - 1) {
            // 2 for word size, 1 to divide by two
            rts_trap_with("Array allocation too large");
        }

        let skewed_ptr = self.alloc_words(size_of::<Array>() + Words(len));

        // NB. Cannot use as_array() here as the header is not written yet
        let ptr: *mut Array = skewed_ptr.get_ptr() as *mut Array;
        (*ptr).header.tag = TAG_ARRAY;
        (*ptr).len = len;

        skewed_ptr
    }

    pub unsafe fn alloc_blob(&mut self, size: Bytes<u32>) -> Value {
        let ptr = self.alloc_words(size_of::<Blob>() + size.to_words());
        // NB. Cannot use as_blob() here as the header is not written yet
        let blob = ptr.get_ptr() as *mut Blob;
        (*blob).header.tag = TAG_BLOB;
        (*blob).len = size;
        ptr
    }

    pub fn hp(&self) -> usize {
        self.hp
    }

    pub fn page_alloc(&self) -> &P {
        &self.page_alloc
    }
}
