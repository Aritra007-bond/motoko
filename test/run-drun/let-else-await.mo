actor {
    public func foo() : async Nat {
        let 2 = 3 else { return await async 4 };
        5;
    };
}

//CALL ingress foo "DIDL\x00\x00"
