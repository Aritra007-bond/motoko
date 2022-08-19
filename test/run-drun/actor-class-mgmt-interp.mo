import Prim "mo:⛔";
import Cycles = "cycles/cycles";
import Cs "actor-class-mgmt/C";

// test gracefull failure of actor class system calls in intrepreters
actor a {

  let default_settings = { settings = null };

  // same as default but explicit
  let settings = { settings = ? {
     controllers = null;
     compute_allocation = null;
     freezing_threshold = null;
     memory_allocation = null;
    };
  };

  public func go () : async () {
    do {

      let c0 = await
         Cs.C 0;
      assert ({args = 0; upgrades = 0} == (await c0.observe()));

      let c1 = await
         (system (#new default_settings) Cs.C(1));
      assert ({args = 1; upgrades = 0} == (await c1.observe()));
      assert (c1 != c0);

      try {
        await async {
          let c2 = await
          (system (#new settings) Cs.C(2));
          assert ({args = 2; upgrades = 0} == (await c2.observe()));
          assert (c2 != c1);
        }
      } catch e {};

      try {
        await async {
          let p = Prim.principalOfBlob("");
          let c3 = await
            (system (#install p) Cs.C(3));
          assert false;
        };
      } catch e { };

      try {
        await async {
          let c4 = await
            (system (#upgrade c1) Cs.C(4));
          assert false;
        }
      } catch e { };

      try {
        await async {
          let c5 = await
            (system (#reinstall c1) Cs.C(5));
          assert false;
        }
      }
      catch e {};
    };

  };

};

a.go(); //OR-CALL ingress go "DIDL\x00\x00"

//SKIP comp-ref
//SKIP ic-ref-run
//SKIP drun-run
