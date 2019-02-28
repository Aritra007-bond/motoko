open Ir   
open Type

(* A miscellany of helpers to construct typed terms from typed terms *)

(* For convenience, fresh identifiers are returned as expressions, and binders
   take expressions (that must be variables) as arguments.
   This makes code transformations easier to write and read,
   at the loss of some precision in OCaml typing.
*)

type var = exp

(* Mutabilities *)

val varM : mut
val constM : mut

(* Field names *)

val nameN : string -> name
val nextN : name

(* Identifiers *)

val fresh_id : unit -> id
val fresh_var : typ -> var

val idE : id -> typ -> exp
val id_of_exp : exp -> id

(* Patterns *)

val varP : var -> pat
val tupP :  pat list -> pat

val seqP : pat list -> pat
val as_seqP : pat -> pat list

(* Expressions *)

val primE : string -> typ -> exp
val projE : exp ->  int -> exp
val decE : dec -> exp
val blockE : dec list -> exp
val textE : string -> exp
val letE : var -> exp -> exp -> exp

val unitE : exp
val boolE : bool -> exp

val callE : exp -> typ list -> exp -> typ -> exp

val ifE : exp -> exp -> exp -> typ -> exp
val dotE : exp -> name -> typ -> exp
val switch_optE : exp -> exp -> pat -> exp -> typ -> exp
val tupE : exp list -> exp
val breakE: id -> exp -> exp
val retE: exp -> exp
val assignE : exp -> exp -> exp
val labelE : id -> typ -> exp -> exp
val loopE : exp -> exp option -> exp

val declare_idE : id -> typ -> exp -> exp
val define_idE : id -> mut -> exp -> exp
val newObjE : obj_sort -> (name * id) list -> typ -> exp

(* Declarations *)

val letP : pat -> exp -> dec   (* TBR: replace letD? *)

val letD : var -> exp -> dec
val varD : id -> exp -> dec
val expD : exp -> dec
val funcD : var -> var -> exp -> dec
val nary_funcD : var  -> var list -> exp -> dec

val is_expD : dec -> bool

(* Continuations *)

val answerT : typ
val contT : typ -> typ
val cpsT : typ -> typ
val fresh_cont : typ -> var

(* Sequence expressions *)

val seqE : exp list -> exp
val as_seqE : exp -> exp list

(* Lambdas *)

val (-->) : var -> exp -> exp
val (-->*) : var list -> exp -> exp (* n-ary local *)
val (-@>*) : var list -> exp -> exp (* n-ary shared *)
val (-*-) : exp -> exp -> exp       (* application *)


(* intermediate, cps-based @async and @await primitives,
   introduced by await(opt).ml to be removed by async.ml *)

val prim_async : typ -> exp

val prim_await : typ -> exp

