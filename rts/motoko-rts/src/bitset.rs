//! This module implements a simple bit set to be used by the compiler (in generated code)

use crate::idl_trap_with;

#[repr(packed)]
pub struct BitSet {
    /// Pointer into the bit set
    pub ptr: *mut u8,
    /// Pointer to the end of the bit set
    pub end: *mut u8,
}

impl BitSet {
    #[cfg(feature = "ic")]
    pub(crate) unsafe fn set(self: *mut Self, n: u32) {
        let byte = (n / 8) as usize;
        let bit = (n % 8) as u8;
        let dst = (*self).ptr.add(byte);
        if dst > (*self).end {
            idl_trap_with("BitSet.set out of bounds");
        };
        *dst = *dst | (1 << bit);
    }

    pub(crate) unsafe fn get(self: *mut Self, n: u32) -> bool {
        let byte = (n / 8) as usize;
        let bit = (n % 8) as u8;
        let src = (*self).ptr.add(byte);
        if src > (*self).end {
            idl_trap_with("BitSet.get out of bounds");
        };
        let mask = 1 << bit;
        return *src & mask == mask;
    }
}

#[repr(packed)]
pub struct BitRel {
    /// Pointer into the bit set
    pub ptr: *mut u8,
    /// Pointer to the end of the bit set
    pub end: *mut u8,
    pub n: u32,
    pub m: u32,
}

impl BitRel {
    pub(crate) unsafe fn clear(self: *mut Self) {
        let mut ptr = (*self).ptr;
        while ptr < (*self).end {
            *ptr = 0;
            ptr = ptr.add(1);
        }
    }

    pub(crate) unsafe fn set(self: *mut Self, p: bool, i_j: u32, j_i: u32) {
        let n = (*self).n;
        let m = (*self).m;
        let (i, j, base) = if p { (0, i_j, j_i) } else { (n * m, j_i, i_j) };
        if i >= n {
            idl_trap_with("BitRel.set i out of bounds");
        };
        if j >= m {
            idl_trap_with("BitRel.set j out of bounds");
        };
        let k = base + i * m + j;
        let byte = (k / 8) as usize;
        let bit = (k % 8) as u8;
        let dst = (*self).ptr.add(byte);
        if dst > (*self).end {
            idl_trap_with("BitRel.set out of bounds");
        };
        *dst = *dst | (1 << bit);
    }

    pub(crate) unsafe fn get(self: *mut Self, p: bool, i_j: u32, j_i: u32) -> bool {
        let n = (*self).n;
        let m = (*self).m;
        let (i, j, base) = if p { (0, i_j, j_i) } else { (n * m, j_i, i_j) };
        if i >= n {
            idl_trap_with("BitRel.set i out of bounds");
        };
        if j >= m {
            idl_trap_with("BitRel.set j out of bounds");
        };
        let k = base + i * m + j;
        let byte = (k / 8) as usize;
        let bit = (k % 8) as u8;
        let src = (*self).ptr.add(byte);
        if src > (*self).end {
            idl_trap_with("BitRel.get out of bounds");
        };
        let mask = 1 << bit;
        return *src & mask == mask;
    }
}
