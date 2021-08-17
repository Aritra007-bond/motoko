use crate::page_alloc::TestPageAlloc;

use motoko_rts::gc::mark_compact::mark_stack::MarkStack;
use motoko_rts::page_alloc::PageAlloc;

use proptest::test_runner::{Config, TestCaseError, TestCaseResult, TestRunner};

pub unsafe fn test() {
    println!("Testing mark stack ...");

    test_push_pop();
}

fn test_push_pop() {
    println!("  Testing push/pop");

    let mut proptest_runner = TestRunner::new(Config {
        cases: 100,
        failure_persistence: None,
        ..Default::default()
    });

    proptest_runner
        .run(&(0u32..1000u32), |n_objs| {
            let mut page_alloc = TestPageAlloc::new(1024); // 1 KiB
            test_(&mut page_alloc, n_objs)
        })
        .unwrap();
}

fn test_<P: PageAlloc>(page_alloc: &mut P, n_objs: u32) -> TestCaseResult {
    let objs: Vec<u32> = (0..n_objs).collect();

    unsafe {
        let mut mark_stack = MarkStack::new(page_alloc.clone());

        for obj in &objs {
            // Pushing a dummy argument derived from `obj` for tag
            mark_stack.push(*obj as usize, obj.wrapping_sub(1));
        }

        for obj in objs.iter().copied().rev() {
            let popped = mark_stack.pop();
            if popped != Some((obj as usize, obj.wrapping_sub(1))) {
                mark_stack.free();
                return Err(TestCaseError::Fail(
                    format!(
                        "Unexpected object popped, expected={:?}, popped={:?}",
                        obj, popped
                    )
                    .into(),
                ));
            }
        }

        mark_stack.free();
    }

    Ok(())
}
