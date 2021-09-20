/// Simple counter (see `Counter.mo`), but uses `mo:base/CertifiedData` to
/// implement the counter value as a certified variable.
import CD "mo:base/CertifiedData";
import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Nat32 "mo:base/Nat32";

actor Counter {

  var value : Nat32 = 0;

  /// Helper; should be in base?
  func blobOfNat32(n : Nat32) : Blob {
    let byteMask : Nat32 = 0xff;
    func byte(n : Nat32) : Nat8 { Nat8.fromNat(Nat32.toNat(n)) };
    Blob.fromArray(
      [byte(byteMask << 0 & value),
       byte(byteMask << 8 & value),
       byte(byteMask << 16 & value),
       byte(byteMask << 24 & value)])
  };

  /// Update counter and certificate (via system).
  public func inc() : async Nat32 {
    value += 1;
    CD.set(blobOfNat32(value));
    return value;
  };

  /// Returns the current counter value,
  /// and an unforgeable certificate (from the system) about its authenticity.
  public query func get() : async ?{ value : Nat32; certificate : Blob } {
    do ? {
      { value; certificate = CD.getCertificate()! }
    }
  };
}
