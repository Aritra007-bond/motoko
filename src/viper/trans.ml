open Source

open Syntax

module T = Mo_types.Type
module M = Mo_def.Syntax
module Arrange = Mo_def.Arrange

module Stamps = Env.Make(String)

(* symbol generation *)

let stamps : int Stamps.t ref = ref Stamps.empty

let reset_stamps () = stamps := Stamps.empty

let fresh_stamp name =
  let n = Lib.Option.get (Stamps.find_opt name !stamps) 0 in
  stamps := Stamps.add name (n + 1) !stamps;
  n

let fresh_id name =
  let n = fresh_stamp name in
  if n = 0 then
    name
  else Printf.sprintf "%s_%i" name (fresh_stamp name)

(* helpers for constructing annotated syntax *)

let (^^^) at it note = { it; at; note}

let (!!!) at it = (^^^) at it NoInfo


let intLitE at i =
  !!! at (IntLitE (Mo_values.Numerics.Int.of_int i))

let accE at fldacc =
  !!! at
    (AccE(
         fldacc,
         !!! at (PermE (!!! at FullP))))

let conjoin es at =
  match es with
  | [] -> !!! at (BoolLitE true)
  | e0::es0 ->
    List.fold_left
      (fun e1 -> fun e2 ->
        !!! at (AndE(e1, e2)))
        e0
        es0

let rec adjoin ctxt e = function
  | [] -> e
  | f :: fs -> f ctxt (adjoin ctxt e fs)


(* exception for reporting unsupported Motoko syntax *)
exception Unsupported of Source.region * string

let unsupported at sexp =
  raise (Unsupported (at, (Wasm.Sexpr.to_string 80 sexp)))

type sort = Field | Local | Method

module Env = T.Env

type ctxt =
  { self : string option;
    ids : sort T.Env.t;
    ghost_items : (ctxt -> item) list ref;
    ghost_inits : (ctxt -> stmt) list ref;
    ghost_perms : (ctxt -> Source.region -> exp) list ref;
    ghost_conc : (ctxt -> exp -> exp) list ref;
  }

let self ctxt at =
  match ctxt.self with
  | Some id -> !!! at (LocalVar (!!! at id,!!! at RefT))
  | _ -> failwith "no self"

let rec extract_invariants : item list -> (par -> invariants -> invariants) = function
  | [] -> fun _ x -> x
  | { it = InvariantI (s, e); at; _ } :: p ->
      fun self es ->
        !!! at (MacroCall(s, !!! at (LocalVar (fst self, snd self))))
        :: extract_invariants p self es
  | _ :: p -> extract_invariants p

let rec extract_concurrency (seq : seqn) : stmt' list * seqn =
  let open List in
  let extr (concs, stmts) s : stmt' list * stmt list =
    match s.it with
    | ConcurrencyS _ -> s.it :: concs, stmts
    | SeqnS seq ->
      let concs', seq = extract_concurrency seq in
      rev_append concs' concs, { s with it = SeqnS seq } :: stmts
    | WhileS (e, inv, seq) ->
      let concs', seq = extract_concurrency seq in
      rev_append concs' concs, { s with it = WhileS (e, inv, seq) } :: stmts
    | IfS (e, the, els) ->
      let the_concs, the = extract_concurrency the in
      let els_concs, els = extract_concurrency els in
      rev_append els_concs (rev_append the_concs concs), { s with it = IfS (e, the, els) } :: stmts
    | _ -> concs, s :: stmts in

  let stmts = snd seq.it in
  let conc, stmts = List.fold_left extr ([], []) stmts in
  rev conc, { seq with it = fst seq.it, rev stmts }

let rec unit (u : M.comp_unit) : prog Diag.result =
  Diag.(
    reset_stamps();
    try return (unit' u) with
    | Unsupported (at, desc) -> error at "0" "viper" ("translation to viper failed:\n"^desc)
    | _ -> error u.it.M.body.at "1" "viper" "translation to viper failed"
  )

and unit' (u : M.comp_unit) : prog =
  let { M.imports; M.body } = u.it in
  match body.it with
  | M.ActorU(id_opt, decs) ->
    let ctxt = { self = None; ids = Env.empty; ghost_items = ref []; ghost_inits = ref []; ghost_perms = ref []; ghost_conc = ref [] } in
    let ctxt', inits, mk_is = dec_fields ctxt decs in
    let is' = List.map (fun mk_i -> mk_i ctxt') mk_is in
    (* given is', compute ghost_is *)
    let ghost_is = List.map (fun mk_i -> mk_i ctxt') !(ctxt.ghost_items) in
    let init_id = !!! (Source.no_region) "__init__" in
    let self_id = !!! (Source.no_region) "$Self" in
    let self_typ = !!! (self_id.at) RefT in
    let ctxt'' = { ctxt' with self = Some self_id.it } in
    let perms = List.map (fun (id, _) -> fun (at : region) ->
       (accE at (self ctxt'' at, id))) inits in
    let ghost_perms = List.map (fun mk_p -> mk_p ctxt'') !(ctxt.ghost_perms) in
    let perm =
      fun (at : region) ->
       List.fold_left
         (fun pexp -> fun p_fn ->
           !!! at (AndE(pexp, p_fn at)))
         (!!! at (BoolLitE true))
         (perms @ ghost_perms)
    in
    (* Add initializer *)
    let init_list = List.map (fun (id, init) ->
        !!! { left = id.at.left; right = init.at.right }
          (FieldAssignS((self ctxt'' init.at, id), exp ctxt'' init)))
        inits in
    let init_list = init_list @ List.map (fun mk_s -> mk_s ctxt'') !(ctxt.ghost_inits) in
    let init_body =
      !!! (body.at) ([], init_list)(* ATG: Is this the correct position? *)
    in
    let init_m =
      (^^^) (body.at) (MethodI(init_id, [self_id, self_typ], [], [], [], Some init_body)) ActorInit
    in
    let is'' = init_m :: is' in
    (* Add permissions *)
    let is''' = List.map (function
    | {it = MethodI (id, ins, outs, pres, posts, body); at; note: info} ->
      (^^^)
        at
        (MethodI (id, ins, outs,
          !!! at (MacroCall("$Perm", self ctxt'' at))::pres,
          !!! at (MacroCall("$Perm", self ctxt'' at))::posts,
          body))
        note
      | x -> x) is'' in
    (* Add functional invariants to public functions *)
    let invs = extract_invariants is''' (self_id, self_typ) [] in
    let is4 = List.map (function
      | {
        it = MethodI (id, ins, outs, pres, posts, body);
        at;
        note = ActorInit
      } -> ((^^^)
        at
        (MethodI(id, ins, outs,
          pres,
          posts @ [!!! at (MacroCall("$Inv", self ctxt'' at))],
          body))
        ActorInit
      )
      | {
        it = MethodI (id, ins, outs, pres, posts, body);
        at;
        note = PublicFunction x
      } -> ((^^^)
        at
        (MethodI(id, ins, outs,
          pres @ [!!! at (MacroCall("$Inv", self ctxt'' at))],
          posts @ [!!! at (MacroCall("$Inv", self ctxt'' at))],
          body))
        (PublicFunction x)
      )
      | x -> x
    ) is''' in
    let perm_def = !!! (body.at) (InvariantI("$Perm", perm body.at)) in
    let inv_def = !!! (body.at) (InvariantI("$Inv", adjoin ctxt'' (conjoin invs body.at) !(ctxt.ghost_conc))) in
    let is = ghost_is @ (perm_def :: inv_def :: is4) in
    !!! (body.at) is
  | _ -> assert false

and dec_fields (ctxt : ctxt) (ds : M.dec_field list) =
  match ds with
  | [] ->
    (ctxt, [], [])
  | d :: ds ->
    let ctxt, init, mk_i = dec_field ctxt d in
    let ctxt, inits, mk_is = dec_fields ctxt ds in
    (ctxt, (match init with Some i -> i::inits | _ -> inits), mk_i::mk_is)

and dec_field ctxt d =
  let ctxt, init, mk_i = dec_field' ctxt d.it in
   (ctxt,
    init,
    fun ctxt' ->
      let (i, info) = mk_i ctxt' in
      (^^^) (d.at) i info)

and dec_field' ctxt d =
  match d.M.dec.it with
  | M.VarD (x, e) ->
      { ctxt with ids = Env.add x.it Field ctxt.ids },
      Some (id x, e),
      fun ctxt' ->
        (FieldI(id x, tr_typ e.note.M.note_typ),
        NoInfo)
  (* async functions *)
  | M.(LetD ({it=VarP f;_},
             {it=FuncE(x, sp, tp, p, t_opt, sugar,
                       {it = AsyncE (T.Fut, _, e); _} );_})) -> (* ignore async *)
      { ctxt with ids = Env.add f.it Method ctxt.ids },
      None,
      fun ctxt' ->
        let open Either in
        let self_id = !!! (Source.no_region) "$Self" in
        let ctxt'' = { ctxt' with self = Some self_id.it }
        in (* TODO: add args (and rets?) *)
        let stmts = stmt ctxt'' e in
        let _, stmts = extract_concurrency stmts in
        let pres, stmts' = List.partition_map (function { it = PreconditionS exp; _ } -> Left exp | s -> Right s) (snd stmts.it) in
        let posts, stmts' = List.partition_map (function { it = PostconditionS exp; _ } -> Left exp | s -> Right s) stmts' in
        (MethodI(id f, (self_id, !!! Source.no_region RefT)::args p, rets t_opt, pres, posts, Some { stmts with it = fst stmts.it, stmts' } ),
        PublicFunction f.it)
  (* private sync functions *)
  | M.(LetD ({it=VarP f;_},
             {it=FuncE(x, sp, tp, p, t_opt, sugar, e );_})) ->
      { ctxt with ids = Env.add f.it Method ctxt.ids },
      None,
      fun ctxt' ->
        let open Either in
        let self_id = !!! (Source.no_region) "$Self" in
        let ctxt'' = { ctxt' with self = Some self_id.it }
        in (* TODO: add args (and rets?) *)
        let stmts = stmt ctxt'' e in
        let _, stmts = extract_concurrency stmts in
        let pres, stmts' = List.partition_map (function { it = PreconditionS exp; _ } -> Left exp | s -> Right s) (snd stmts.it) in
        let posts, stmts' = List.partition_map (function { it = PostconditionS exp; _ } -> Left exp | s -> Right s) stmts' in
        (MethodI(id f, (self_id, !!! Source.no_region RefT)::args p, rets t_opt, pres, posts, Some { stmts with it = fst stmts.it, stmts' } ),
        PrivateFunction f.it)
  | M.(ExpD { it = AssertE (Invariant, e); at; _ }) ->
      ctxt,
      None,
      fun ctxt' ->
        (InvariantI (Printf.sprintf "invariant_%d" at.left.line, exp { ctxt' with self = Some "$Self" }  e), NoInfo)
  | _ ->
     unsupported d.M.dec.at (Arrange.dec d.M.dec)

and args p = match p.it with
  | M.TupP ps ->
    List.map
      (fun p ->
        match p.it with
        | M.VarP x ->
          (id x, tr_typ p.note)
        | _ -> unsupported p.at (Arrange.pat p))
      ps
  |  _ -> unsupported p.at (Arrange.pat p)

and block ctxt at ds =
  let ctxt, mk_ss = decs ctxt ds in
  !!! at (mk_ss ctxt)

and decs ctxt ds =
  match ds with
  | [] -> (ctxt, fun ctxt' -> ([],[]))
  | d::ds' ->
    let (ctxt1, mk_s) = dec ctxt d in
    let (ctxt2, mk_ss) = decs ctxt1 ds' in
    (ctxt2,
     fun ctxt' ->
       let (l, s) = mk_s ctxt' in
       let (ls, ss) = mk_ss ctxt' in
       (l @ ls, s @ ss))

and dec ctxt d =
  let (!!) p = !!! (d.at) p in
  match d.it with
  | M.VarD (x, e) ->
     (* TODO: translate e? *)
    { ctxt with ids = Env.add x.it Local ctxt.ids },
    fun ctxt' ->
      ([ !!(id x, tr_typ e.note.M.note_typ) ],
       [ !!(VarAssignS (id x, exp ctxt' e)) ])
  | M.(LetD ({it=VarP x;_}, e)) ->
     { ctxt with ids = Env.add x.it Local ctxt.ids },
     fun ctxt' ->
       ([ !!(id x, tr_typ e.note.M.note_typ) ],
        [ !!(VarAssignS (id x, exp ctxt' e)) ])
  | M.(ExpD e) -> (* TODO: restrict to e of unit type? *)
     (ctxt,
      fun ctxt' ->
        let s = stmt ctxt' e in
        s.it)
  | _ ->
     unsupported d.at (Arrange.dec d)

and stmt ctxt (s : M.exp) : seqn =
  let (!!) p = !!! (s.at) p in
  match s.it with
  | M.TupE [] ->
     block ctxt s.at []
  | M.BlockE ds ->
     block ctxt s.at ds
  | M.IfE(e, s1, s2) ->
    !!([],
       [ !!(IfS(exp ctxt e, stmt ctxt s1, stmt ctxt s2))])
  | M.(AwaitE(T.Fut, { it = AsyncE (T.Fut, _, e); at; _ })) -> (* gross hack *)
     let id = fresh_id "$message_async" in
     let (!!) p = !!! (s.at) p in
     let (!@) p = !!! at p in
     ctxt.ghost_items :=
       (fun ctxt ->
         !!(FieldI (!!id, !!IntT))) ::
       !(ctxt.ghost_items);
     let mk_s = fun ctxt ->
       !!! at
         (FieldAssignS (
            (self  ctxt s.at, !!id),
            intLitE (s.at) 0))
     in
     ctxt.ghost_inits := mk_s :: !(ctxt.ghost_inits);
     let mk_p = fun ctxt at ->
       accE at (self ctxt at, !!! at id)
     in
     ctxt.ghost_perms := mk_p :: !(ctxt.ghost_perms);
     let stmts = stmt ctxt e in
     (* assume that each `async {...}` has an assertion *)
     let conc, _ = extract_concurrency stmts in
     let mk_c = match conc with
       | [] ->
         fun _ x -> x
       | ConcurrencyS ("1", _, cond) :: _ ->
         let (!?) p = !!! (cond.at) p in
         let zero, one = intLitE Source.no_region 0, intLitE Source.no_region 1 in
         fun ctxt x ->
           let ghost_fld () = !?(FldAcc (self ctxt cond.at, !?id)) in
           let between = !?(AndE (!?(LeCmpE (zero, ghost_fld ())), !?(LeCmpE (ghost_fld (), one)))) in
           let is_one = !?(EqCmpE (ghost_fld (), one)) in
           !?(AndE (x, !?(AndE (between, !?(Implies (is_one, cond.it (exp ctxt)))))))
       | _ -> unsupported e.at (Arrange.exp e) in
     ctxt.ghost_conc := mk_c :: !(ctxt.ghost_conc);
     !!([],
        [ !!(FieldAssignS(
            (self ctxt Source.no_region, !!id),
            (!!(AddE(!!(FldAcc (self ctxt (s.at), !!id)),
                     intLitE Source.no_region 1)))));
          !@(ExhaleS (!@(AndE(!@(MacroCall("$Perm", self ctxt at)),
                              !@(MacroCall("$Inv", self ctxt at))))));
          !@(SeqnS (
              !@([],
                 [
                   !@(InhaleS (!@(AndE(!@(MacroCall("$Perm", self ctxt at)),
                                  !@(AndE(!@(MacroCall("$Inv", self ctxt at)),
                                          !@(GtCmpE(!@(FldAcc (self ctxt at, !@id)),
                                               intLitE Source.no_region 0))))))));
                   !@(FieldAssignS(
                          (self ctxt at, !@id),
                          (!@(SubE(!@(FldAcc (self ctxt at, !@id)),
                                   intLitE at 1)))));
                   !!! (e.at) (SeqnS stmts);
                   !@(ExhaleS (!@(AndE(!@(MacroCall("$Perm", self ctxt at)),
                                       !@(MacroCall("$Inv", self ctxt at)))))) ])));
          !!(InhaleS (!!(AndE(!!(MacroCall("$Perm", self ctxt at)),
                              !!(MacroCall("$Inv", self ctxt at))))));
        ])
  | M.WhileE(e, s1) ->
     !!([],
        [ !!(WhileS(exp ctxt e, [], stmt ctxt s1)) ]) (* TODO: Invariant *)
  | M.(AssignE({it = VarE x; _}, e2)) ->
     begin match Env.find x.it ctxt.ids with
     | Local ->
       let loc = !!! (x.at) (x.it) in
       !!([],
          [ !!(VarAssignS(loc, exp ctxt e2)) ])
     | Field ->
       let fld = (self ctxt x.at, id x) in
       !!([],
          [ !!(FieldAssignS(fld, exp ctxt e2)) ])
     | _ ->
        unsupported s.at (Arrange.exp s)
     end
  | M.AssertE (M.Precondition, e) ->
    !!( [],
        [ !!(PreconditionS (exp ctxt e)) ])
  | M.AssertE (M.Postcondition, e) ->
    !!([],
       [ !!(PostconditionS (exp ctxt e)) ])
  | M.AssertE (M.Concurrency n, e) ->
    !!([],
       [ !!(ConcurrencyS (n, exp ctxt e, !! ((|>) e))) ])
  | M.AssertE (M.Static, e) ->
    !!([],
       [ !!(AssertS (exp ctxt e)) ])
  | M.AssertE (M.Runtime, e) ->
    !!([],
       [ !!(AssumeS (exp ctxt e)) ])
  | M.(CallE({it = VarE m; _}, inst, {it = TupE args; _})) ->
    !!([],
       [ !!(MethodCallS ([], id m, 
       let self_var = self ctxt m.at in
       self_var :: List.map (fun arg -> exp ctxt arg) args))])
  | _ ->
     unsupported s.at (Arrange.exp s)

and exp ctxt e =
  let open Mo_values.Operator in
  let (!!) p = !!! (e.at) p in
  match e.it with
  | M.VarE x ->
    begin
     match Env.find x.it ctxt.ids with
     | Local ->
        !!(LocalVar (id x, tr_typ e.note.M.note_typ))
     | Field ->
        !!(FldAcc (self ctxt x.at, id x))
     | _ ->
        unsupported e.at (Arrange.exp e)
    end
  | M.AnnotE(a, b) ->
    exp ctxt a
  | M.LitE r ->
    begin match !r with
    | M.BoolLit b ->
       !!(BoolLitE b)
    | M.IntLit i ->
       !!(IntLitE i)
    | _ ->
       unsupported e.at (Arrange.exp e)
    end
  | M.NotE e ->
     !!(NotE (exp ctxt e))
  | M.RelE (ot, e1, op, e2) ->
     let e1, e2 = exp ctxt e1, exp ctxt e2 in
     !!(match op with
      | EqOp -> EqCmpE (e1, e2)
      | NeqOp -> NeCmpE (e1, e2)
      | GtOp -> GtCmpE (e1, e2)
      | GeOp -> GeCmpE (e1, e2)
      | LtOp -> LtCmpE (e1, e2)
      | LeOp -> LeCmpE (e1, e2))
  | M.BinE (ot, e1, op, e2) ->
     let e1, e2 = exp ctxt e1, exp ctxt e2 in
     !!(match op with
      | AddOp -> AddE (e1, e2)
      | SubOp -> SubE (e1, e2)
      | MulOp -> MulE (e1, e2)
      | DivOp -> DivE (e1, e2)
      | ModOp -> ModE (e1, e2)
      | _ -> unsupported e.at (Arrange.exp e))
  | M.OrE (e1, e2) ->
     !!(OrE (exp ctxt e1, exp ctxt e2))
  | M.AndE (e1, e2) ->
     !!(AndE (exp ctxt e1, exp ctxt e2))
  | M.ImpliesE (e1, e2) ->
     !!(Implies (exp ctxt e1, exp ctxt e2))
  | M.OldE e ->
    !!(Old (exp ctxt e))
  | _ ->
     unsupported e.at (Arrange.exp e)

and rets t_opt =
  match t_opt with
  | None -> []
  | Some t ->
    (match T.normalize t.note with
     | T.Tup [] -> []
     | T.Async (T.Fut, _, _) -> []
     | _ -> unsupported t.at (Arrange.typ t)
    )

and id id = { it = id.it; at = id.at; note = NoInfo }

and tr_typ typ =
  { it = tr_typ' typ;
    at = Source.no_region;
    note = NoInfo }
and tr_typ' typ =
  match T.normalize typ with
  | T.Prim T.Int -> IntT
  | T.Prim T.Bool -> BoolT
  | _ -> unsupported Source.no_region (Mo_types.Arrange_type.typ (T.normalize typ))
