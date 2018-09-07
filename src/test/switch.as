let x1 = switch 2 {
  case (0) 0
  case (2) 1
  case (_) 2
};

let x2 : Int = switch (-3) {
  case (0) 0
  case (-1) 2
  case (-3) 1
  case (x) x
};

let x3 = switch 4 {
  case 0 (+0)
  case 2 (-1)
  case x (x-3)
};

let x4 = switch (null : {}?) {
  case null 1
  case _ 0
};

let x5 = switch (new {}?) {
  case null 0
  case x 1
};

let oo : {}? = new {};
let x6 = switch oo {
  case null 0
  case _ 1
};

let no : Nat? = 0;
let x7 = switch no {
  case null 0
  case 0 1
  case n n
};

let x8 = switch 3 {
  case (0; 1) 0
  case (3; 4) 1
  case _ 2
};

let x9 = switch 4 {
  case (0; 1) 0
  case (3; 4; 5) 1
  case _ 2
};
