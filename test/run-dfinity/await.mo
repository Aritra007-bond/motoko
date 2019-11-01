var cnt : Nat = 0;

func f(i:Nat) : async Nat {
    print "cnt: ";
    printNat cnt;
    print " i: ";
    printNat i;
    print "\n";
    cnt += 1;
    cnt;
};

print "a";

let a = async await f(0);

print "b";

let b = async { await f(1); };

print "c";

let c = async {
    let _ = await f(2);
    await f(3);
};

print "d";

let d  = (async { return await f(4); }) : async Int; 

print "e";

let e = async {
    var i = 5;
    print "e-while";
    while (i < 8) {
	let _ = await f(i);
	i += 1;
    };
    print "e-exit";
};

print "g";

let g = async {
    var i = 10;
    print "g-label";
    label lp
    while (true) {
	if (i < 13) {
    	    print ".";
     	    let _ = await f(i);
     	    i += 1;
	    continue lp; 
	} else {};
	break lp;
    };
    print "g-exit";
};

print "holy";

func p():async (Text,Text) { ("fst","snd"); };
let h = async {
   let (a,b) = ("a","b"); /* await p(a,b);*/
   print a;
   print b;
};

