module {
 /*
  public class Id<A>(x : A) {
    public func map<B>(f : A -> B) : Id<B> = Id(f x)
  }
  */

 type Id<A> = object { map : <B>(A->B) -> Id<B> }; // note polymorphic recursion
}

