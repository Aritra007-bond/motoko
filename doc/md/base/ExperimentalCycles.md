# ExperimentalCycles
Managing cycles

Usage of the Internet Computer is measured, and paid for, in _cycles_.
This library provides imperative operations for observing cycles, transferring cycles and
observing refunds of cycles.

**WARNING:** This low-level API is **experimental** and likely to change or even disappear.
Dedicated syntactic support for manipulating cycles may be added to the language in future, obsoleting this library.

**NOTE:** Since cycles measure computational resources, the value of
`balance()` can change from one call to the next.

## Value `balance`
``` motoko no-repl
let balance : () -> (amount : Nat)
```

Returns the actor's current balance of cycles as `amount`.

## Value `available`
``` motoko no-repl
let available : () -> (amount : Nat)
```

Returns the currently available `amount` of cycles.
The amount available is the amount received in the current call,
minus the cumulative amount `accept`ed by this call.
On exit from the current shared function or async expression via `return` or `throw`
any remaining available amount is automatically
refunded to the caller/context.

## Value `accept`
``` motoko no-repl
let accept : (amount : Nat) -> (accepted : Nat)
```

Transfers up to `amount` from `available()` to `balance()`.
Returns the amount actually transferred, which may be less than
requested, for example, if less is available, or if canister balance limits are reached.

## Value `add`
``` motoko no-repl
let add : (amount : Nat) -> ()
```

Indicates additional `amount` of cycles to be transferred in
the next call, that is, evaluation of a shared function call or
async expression.
Traps if the current total would exceed 2^128 cycles.
Upon the call, but not before, the total amount of cycles ``add``ed since
the last call is deducted from `balance()`.
If this total exceeds `balance()`, the caller traps, aborting the call.

**Note**: the implicit register of added amounts is reset to zero on entry to
a shared function and after each shared function call or resume from an await.

## Value `refunded`
``` motoko no-repl
let refunded : () -> (amount : Nat)
```

Reports `amount` of cycles refunded in the last `await` of the current
context, or zero if no await has occurred yet.
Calling `refunded()` is solely informational and does not affect `balance()`.
Instead, refunds are automatically added to the current balance,
whether or not `refunded` is used to observe them.
