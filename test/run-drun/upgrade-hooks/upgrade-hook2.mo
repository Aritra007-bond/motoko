import Prim "mo:prim";
actor {
  Prim.debugPrint ("init'ed 2");
  stable let c : Text = { assert false; loop {}};
  stable var i : Nat = { assert false; loop {}};
  var j = i; // cached state
  public func inc() { j += 1; };
  public query func check(n : Int) : async () {
    assert (c.len() == 3);
    assert (j == n);
  };
  system func preupgrade(){
    Prim.debugPrint("preupgrade 2");
    i := j; // save cache
  };
  system func postupgrade(){
    Prim.debugPrint("postupgrade 2");
    j := i; // restore cache
  };

}

