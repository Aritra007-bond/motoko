import Prim "mo:prim";
shared actor class Two(a : Text, b : Text) {

   Prim.debugPrint(debug_show((a,b)));

   public func test() : async () {
      Prim.debugPrint(debug_show((a,b)) # "tested");
   };

}
