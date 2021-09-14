import Prim "mo:⛔";
import StableMemory "stable-mem/StableMemory";

actor {

  func ensure(offset : Nat32) {
    let pages = (offset + 65536) >> 16;
    if (pages > StableMemory.size()) {
      let oldsize = StableMemory.grow(pages - StableMemory.size());
      assert (oldsize != 0xFFFF);
    };
  };

  stable var base : Nat32 = 0;

  public func log(t : Text) {
    let blob = Prim.encodeUtf8(t);
    let size = Prim.natToNat32(blob.size());
    let next = base + size + 4;
    ensure(next);
    StableMemory.storeBlob(base, blob);
    StableMemory.storeNat32(base + size, size);
    base := next;
  };

  public query func readLast(count : Nat) : async ?[Text] {
    if (base == 0) return null;
    let a = Prim.Array_init<Text>(count, "");
    var offset = base;
    for (k in a.keys()) {
      if (offset == 0) return null;
      offset -= 4;
      let size = StableMemory.loadNat32(offset);
      offset -= size;
      let blob = StableMemory.loadBlob(offset, Prim.nat32ToNat(size));
      switch (Prim.decodeUtf8(blob)) {
        case (?t) {
          a[k] := t;
        };
        case null { return null; }
      };
    };
    return ?Prim.Array_tabulate<Text>(count, func i { a[i] });
  };


  // testing
  stable var count = 0;

  public func populate() : async () {
    // populate
    let limit = count + 100;
    while (count < limit) {
      log(debug_show(count));
      count += 1;
    };
  };

  public func readAll() : async () {
    switch (await readLast(count)) {
      case (?ts) {
        for (t in ts.vals()) {
          Prim.debugPrint(t);
        }
      };
      case null {}
    };
  }
}

//SKIP run
//SKIP run-low
//SKIP run-ir
// too slow on ic-ref-run:
//SKIP comp-ref

//CALL ingress populate "DIDL\x00\x00"
//CALL ingress readAll "DIDL\x00\x00"
//CALL upgrade ""
//CALL ingress populate "DIDL\x00\x00"
//CALL ingress readAll "DIDL\x00\x00"
