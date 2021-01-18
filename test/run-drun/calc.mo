import P "mo:prim";

actor a {

  func power(i:Int, n: Int) : Int {
    if (n<=0) i else i*power(i, n-1);
  };

  public /* query */ func pow(i :Int, n:Int) : async Int {
     power(i, n);
  };

  public type Expression = {
    #const : Int;
    #add : (Expression, Expression);
    #mul : (Expression, Expression);
    #sub : (Expression, Expression);
    #pow : (Expression, Expression);
  };

  func eval(exp : Expression) : Int {
    switch (exp) {
      case (#const(n)) n;
      case (#add(e1, e2)) eval(e1) + eval(e2);
      case (#mul(e1, e2)) eval(e1) * eval(e2);
      case (#sub(e1, e2)) eval(e1) - eval(e2);
      case (#pow(e1, e2)) power(eval e1, eval e2);
    }
  };

  func evalAsync(exp : Expression) : async Int {
    switch (exp) {
      case (#const(n)) n;
      case (#add(e1, e2)) (await evalAsync(e1)) + (await evalAsync(e2));
      case (#mul(e1, e2)) (await evalAsync(e1)) * (await evalAsync(e2));
      case (#sub(e1, e2)) (await evalAsync(e1)) - (await evalAsync(e2));
      case (#pow(e1, e2)) await (pow(await (evalAsync e1), await (evalAsync e2)));
    }
  };

  // Use `do async {}` to avoid context switch at each recursive call
  // Could also just do outermost return instead of in each branch.
  func evalDoAsync(exp : Expression) : async Int = do async {
    switch (exp) {
      case (#const(n)) n;
      case (#add(e1, e2)) (await evalDoAsync(e1)) + (await evalDoAsync(e2));
      case (#mul(e1, e2)) (await evalDoAsync(e1)) * (await evalDoAsync(e2));
      case (#sub(e1, e2)) (await evalDoAsync(e1)) - (await evalDoAsync(e2));
      case (#pow(e1, e2)) await pow(await (evalDoAsync e1), await (evalDoAsync e2));
                              // ^^^ only real context switch on call to asynchronous `pow` query
    }
  };

  func sum(n : Int) : Expression {
     if (n <= 0)
       #const 0
     else #add(#const n,sum (n-1));
  };

  public func evaluate() : async () {
    P.debugPrint "Sync";
    P.debugPrint (debug_show(eval(sum(32))));
    P.debugPrint (debug_show(eval(#pow(#const 2,#const 10))));
  };

  public func evaluateAsync() : async () {
    P.debugPrint "Async";
    P.debugPrint (debug_show(await(evalAsync(sum(32)))));
    P.debugPrint (debug_show(await(evalAsync(#pow(#const 2,#const 10)))));
  };

  public func evaluateDoAsync() : async () {
    P.debugPrint "DoAsync";
    P.debugPrint (debug_show(await(evalDoAsync(sum(32)))));
    P.debugPrint (debug_show(await(evalDoAsync(#pow(#const 2,#const 10)))));
  };
};

await a.evaluate(); //OR-CALL ingress evaluate "DIDL\x00\x00"
await a.evaluateAsync(); //OR-CALL ingress evaluateAsync "DIDL\x00\x00"
await a.evaluateDoAsync(); //OR-CALL ingress evaluateDoAsync "DIDL\x00\x00"
