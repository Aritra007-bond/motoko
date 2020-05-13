(*
This module originated as a copy of interpreter/binary/encode.ml in the
reference implementation.

The changes are:
 * Support for writing out a source map for the Code parts
 * Support for additional custom sections

The code is otherwise as untouched as possible, so that we can relatively
easily apply diffs from the original code (possibly manually).
*)

(* Utility predicates *)

let dwarf_like Wasm.Source.{ left; right } =
  Wasm.Source.(left.line < 0 && left.file = no_pos.file && right = no_pos)

let is_dwarf_statement Wasm.Source.{ left; right } =
  let open Wasm.Source in
  (* we require physical equality for the filename *)
  left.file == right.file
  && right.line < 0 (* special marker *)
  && left.line = - right.line
  && left.column = right.column

module Promise = Lib.Promise

open CustomModule

(* Version *)

let version = 1l


(* Errors *)

module Code = Wasm.Error.Make ()


(* Encoding stream *)

type stream =
{
  buf : Buffer.t;
  patches : (int * char) list ref
}

let stream () = {buf = Buffer.create 8192; patches = ref []}
let pos s = Buffer.length s.buf
let put s b = Buffer.add_char s.buf b
let put_string s bs = Buffer.add_string s.buf bs
let patch s pos b = s.patches := (pos, b) :: !(s.patches)

let to_string s =
  let bs = Buffer.to_bytes s.buf in
  List.iter (fun (pos, b) -> Bytes.set bs pos b) !(s.patches);
  Bytes.to_string bs

module References = Map.Make (struct type t = int let compare = compare end)

let dw_references = ref References.empty
let num_dw_references = ref 1 (* 0 would mean: "this tag doesn't fulfill a reference" *)
let allocate_reference_slot () =
  Printf.printf "ALLOCATED SLOT: %d\n" !num_dw_references;
  let have = !num_dw_references in
  dw_references := References.add have (Promise.make ()) !dw_references;
  num_dw_references := 1 + have;
  have

(* DWARF factlets, a.k.a. DIEs *)

type dwarf_artifact = Tag of int option * int * dwarf_artifact list
                    | IntAttribute of int * int
                    | RangeAttribute of int * int
                    | StringAttribute of int * string
                    | FunctionsAttribute of int

(* Encoding *)

let encode (em : extended_module) =
  let s = stream () in

  (* source map *)
  let map = Buffer.create 0 in
  let sources = ref [] in
  let sourcesContent = ref [] in
  let segs = ref 0 in
  let prev_if = ref 0 in
  let prev_ol = ref 0 in
  let prev_oc = ref 0 in
  let prev_il = ref 0 in
  let prev_ic = ref 0 in

  (* modify reference *)
  let modif r f = r := f !r in

  let rec add_source x = function (* FIXME: use add_string *)
    | [] ->
      sources := !sources @ [ x ];
      sourcesContent := !sourcesContent @ [ "" ];
      0
    | h :: t -> if x = h then 0 else 1 + add_source x t
  in

  sources := !sources @ [ "prelude" ];
  sourcesContent := !sourcesContent @ [ Prelude.prelude ];

  let add_string gen strings str = (* FIXME: perform suffix compression *)
    let strs = !strings in
    match List.assoc_opt str strs with
    | Some v -> v
    | _ ->
      let v = gen strs in
      let strs' = (str, v) :: strs in strings := strs'; v
  in

  let dwarf_strings = ref [] in

  let add_dwarf_string =
    add_string (function | [] -> 0 | (h, p) :: _ -> String.length h + 1 + p) dwarf_strings in

  let module Instrs = Set.Make (struct type t = int * Wasm.Source.pos let compare = compare end) in
  let statement_positions = ref Instrs.empty in

  let module Sequ = Set.Make (struct type t = int * Instrs.t * int let compare = compare end) in
  let sequence_bounds = ref Sequ.empty in

  let dwarf_tags = ref [Tag (None, 0, [])] in

  let is_closed tag =
    let tag_of (t', _, _) = tag = t' in
    let (_, has_children, _) = List.find tag_of Abbreviation.abbreviations in
    not (has_children <> 0)
  in

  let add_dwarf_tag refi tag =
    (* invariant: at most one closed tag waiting for attributes *)
    dwarf_tags :=
      match !dwarf_tags with
      | Tag (_, t', _) as closed :: Tag (r, t, arts) :: tail when is_closed t' ->
        (Printf.printf "CONTRACTING a 0x%x\n" tag; Tag (refi, tag, []) :: Tag (r, t, closed :: arts) :: tail)
      | tail -> Tag (refi, tag, []) :: (Printf.printf "ADDING a 0x%x%s\n" tag (if refi = None then "" else " has ref"); tail) in
  let rec close_dwarf () =
    match !dwarf_tags with
    | [] -> failwith "no open DW_TAG"
    | Tag _ :: [] -> failwith "TOPLEVEL: NOT NESTING"
    | Tag (_, t', _) as closed :: Tag (r, t, arts) :: tail when is_closed t' -> Printf.printf "PUSHING CLOSED\n"; dwarf_tags := Tag (r, t, closed :: arts) :: tail; close_dwarf ()
    | Tag (None, s, attrs_tags) :: Tag (None, 0, tags) :: [] when Dwarf5.dw_TAG_compile_unit = s ->
      Printf.printf "TOPLEVEL: EATING\n";
      (* we have to be careful to only reference tags already written,
         so maintain creation order; reversal happens in writeTag *)
      let ref_priority a b = match a, b with
        | Tag (Some m, _, _), Tag (Some n, _, _) -> compare n m
        | _, Tag (Some _, _, _) -> -1
        | Tag (Some _, _, _), _ -> 1
        | _ -> 0 in
      let refs_back = List.stable_sort ref_priority (attrs_tags @ tags) in
      dwarf_tags := Tag (None, s, refs_back) :: []
    | Tag _ as nested :: Tag (r, tag, arts) :: t -> dwarf_tags := (Printf.printf "NESTING into 0x%x\n" tag; Tag (r, tag, nested :: arts) :: t)
    | _ -> failwith "cannot close DW_AT" in
  let add_dwarf_attribute attr =
    dwarf_tags := match !dwarf_tags with
                  | Tag (r, tag, arts) :: t -> Tag (r, tag, attr :: arts) :: t
                  | _ -> assert false
  in

  (* keeping count of the DWARF code sequence we are in *)
  let sequence_number = ref 0 in

  let extract_dwarf refi tag =
    let open Wasm.Ast in
    let open Wasm.Source in
    let open Dwarf5 in

    let extract = function
      | Nop, {line; file; _} when -line = dw_AT_producer ->
        let _offs = add_dwarf_string file in
        add_dwarf_attribute (StringAttribute (-line, file))
      | Nop, {line; file; _} when -line = dw_AT_name ->
        let _offs = add_dwarf_string file in
        add_dwarf_attribute (StringAttribute (-line, file))
      | Nop, {line; file; _} when -line = dw_AT_comp_dir ->
        let _offs = add_dwarf_string file in
        add_dwarf_attribute (StringAttribute (-line, file))
      | Nop, {line; file; _} when -line = dw_AT_location ->
        add_dwarf_attribute (StringAttribute (-line, file))
      | Nop, {line; column; _} when -line = dw_AT_use_UTF8 ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_language ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_stmt_list ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_low_pc && tag = dw_TAG_subprogram ->
        add_dwarf_attribute (IntAttribute (-line, !sequence_number))
      | Nop, {line; column; _} when -line = dw_AT_low_pc ->
        add_dwarf_attribute (IntAttribute (-line, column))

      | Nop, {line; column; _} when -line = dw_AT_high_pc && tag = dw_TAG_subprogram ->
        add_dwarf_attribute (RangeAttribute (-line, !sequence_number))
      | Nop, {line; column; _} when -line = dw_AT_high_pc ->
        add_dwarf_attribute (IntAttribute (-line, column))


      | Nop, {line; file; _} when -line = dw_AT_decl_file ->
        add_dwarf_attribute (StringAttribute (-line, file))
      | Nop, {line; column; _} when -line = dw_AT_decl_line ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_decl_column ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_prototyped ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_external ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_addr_base ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_byte_size ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_bit_size ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_data_bit_offset ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; _} when -line = dw_AT_ranges ->
        add_dwarf_attribute (FunctionsAttribute (-line))
      | Nop, {line; column; _} when -line = dw_AT_artificial ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_discr ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_const_value ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_discr_value ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_encoding ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; column; _} when -line = dw_AT_type ->
        add_dwarf_attribute (IntAttribute (-line, column))
      | Nop, {line; _} -> Printf.printf "TAG: 0x%x; ATTR extract: 0x%x\n" tag (-line); failwith "extract"
      | instr, {line; file; _} -> Printf.printf "TAG: 0x%x (a.k.a. %d, from: %s); extract: 0x%x\n INSTR %s" tag tag file (-line) (Wasm.Sexpr.to_string 80 (Wasm.Arrange.instr (instr @@ Wasm.Source.no_region))); failwith "extract UNKNOWN"
    in
    add_dwarf_tag (if refi = 0 then None else (Printf.printf "TAGGING REF %d for TAG 0x%x\n" refi tag; Some refi)) tag;
    let rec add_artifacts = function
    | [] -> ()
    | e :: es -> extract (e.it, e.at.left); add_artifacts es in
    add_artifacts
  in

  let add_to_map file il ic ol oc =
    let il = il - 1 in
    let if_ = add_source file !sources in
    if ol <> !prev_ol then Buffer.add_char map ';';
    Vlq.Base64.encode map (oc - !prev_oc);             (* output column *)
    Vlq.Base64.encode map (if_ - !prev_if);            (* sources index *)
    Vlq.Base64.encode map (il - !prev_il);             (* input row *)
    Vlq.Base64.encode map (ic - !prev_ic);             (* input column *)
    Buffer.add_char map ',';

    prev_if := if_; prev_ol := ol; prev_oc := oc; prev_il := il; prev_ic := ic; segs := !segs + 1
  in

  let module E = struct
    (* Generic values *)

    let u8 i = put s (Char.chr (i land 0xff))
    let u16 i = u8 (i land 0xff); u8 (i lsr 8)
    let u32 i =
      Int32.(u16 (to_int (logand i 0xffffl));
             u16 (to_int (shift_right i 16)))
    let u64 i =
      Int64.(u32 (to_int32 (logand i 0xffffffffL));
             u32 (to_int32 (shift_right i 32)))

    let rec vu64 i =
      let b = Int64.(to_int (logand i 0x7fL)) in
      if 0L <= i && i < 128L then u8 b
      else (u8 (b lor 0x80); vu64 (Int64.shift_right_logical i 7))

    let rec vs64 i =
      let b = Int64.(to_int (logand i 0x7fL)) in
      if -64L <= i && i < 64L then u8 b
      else (u8 (b lor 0x80); vs64 (Int64.shift_right i 7))

    let vu1 i = vu64 Int64.(logand (of_int i) 1L)
    let vu32 i = vu64 Int64.(logand (of_int32 i) 0xffffffffL)
    let vs7 i = vs64 (Int64.of_int i)
    let vs32 i = vs64 (Int64.of_int32 i)
    let f32 x = u32 (Wasm.F32.to_bits x)
    let f64 x = u64 (Wasm.F64.to_bits x)

    let len i =
      if Int32.to_int (Int32.of_int i) <> i then
        Code.error Wasm.Source.no_region
          "cannot encode length with more than 32 bit";
      vu32 (Int32.of_int i)

    let bool b = vu1 (if b then 1 else 0)
    let string bs = len (String.length bs); put_string s bs
    let name n = string (Wasm.Utf8.encode n)
    let list f xs = List.iter f xs
    let opt f xo = Option.iter f xo
    let vec_by l f xs = l (List.length xs); list f xs
    let vec f xs = vec_by len f xs

    let gap32 () = let p = pos s in u32 0l; u8 0; p
    let patch_gap32 p n =
      assert (n <= 0x0fff_ffff); (* Strings cannot excess 2G anyway *)
      let lsb i = Char.chr (i land 0xff) in
      patch s p (lsb (n lor 0x80));
      patch s (p + 1) (lsb ((n lsr 7) lor 0x80));
      patch s (p + 2) (lsb ((n lsr 14) lor 0x80));
      patch s (p + 3) (lsb ((n lsr 21) lor 0x80));
      patch s (p + 4) (lsb (n lsr 28))

    (* Types *)

    open Wasm.Types

    let value_type = function
      | I32Type -> vs7 (-0x01)
      | I64Type -> vs7 (-0x02)
      | F32Type -> vs7 (-0x03)
      | F64Type -> vs7 (-0x04)

    let elem_type = function
      | FuncRefType -> vs7 (-0x10)

    let func_type = function
      | FuncType (ins, out) -> vs7 (-0x20); vec value_type ins; vec value_type out

    let limits vu {min; max} =
      bool (max <> None); vu min; opt vu max

    let table_type = function
      | TableType (lim, t) -> elem_type t; limits vu32 lim

    let memory_type = function
      | MemoryType lim -> limits vu32 lim

    let mutability = function
      | Immutable -> u8 0
      | Mutable -> u8 1

    let global_type = function
      | GlobalType (t, mut) -> value_type t; mutability mut

    (* Expressions *)

    open Wasm.Source
    open Wasm.Ast
    open Wasm.Values
    open Wasm.Memory

    let op n = u8 n
    let end_ () = op 0x0b

    let memop {align; offset; _} = vu32 (Int32.of_int align); vu32 offset

    let var x = vu32 x.it

    let stack_type = function
      | [] -> vs7 (-0x40)
      | [t] -> value_type t
      | _ ->
        Code.error Wasm.Source.no_region
          "cannot encode stack type with arity > 1 (yet)"

    let rec instr' noting e =
      if e.at <> no_region then add_to_map e.at.left.file e.at.left.line e.at.left.column 0 (pos s);
      noting e;
      let instr = instr' noting in

      match e.it with
      | Nop when dwarf_like e.at -> close_dwarf ()
      | Nop when is_dwarf_statement e.at ->
        Printf.printf "Line %d    OFFS: 0x%x     (%s:%d:%d)\n" e.at.right.line (pos s) e.at.left.file e.at.left.line e.at.left.column;
        modif statement_positions (Instrs.add (pos s, e.at.left))
      | Block (_, es) when dwarf_like e.at -> extract_dwarf (e.at.left.column) (-e.at.left.line) es
      (*  | _ when (if S.mem e.at.left !statement_positions then Printf.printf "ENCOUNTERED File %s Line %d    ADDR: %x\n" e.at.left.file e.at.left.line (pos s); false) -> assert false; *)

      | Unreachable -> op 0x00
      | Nop -> op 0x01

      | Block (ts, es) -> op 0x02; stack_type ts; list instr es; end_ ()
      | Loop (ts, es) -> op 0x03; stack_type ts; list instr es; end_ ()
      | If (ts, es1, es2) ->
        op 0x04; stack_type ts; list instr es1;
        if es2 <> [] then op 0x05;
        list instr es2; end_ ()

      | Br x -> op 0x0c; var x
      | BrIf x -> op 0x0d; var x
      | BrTable (xs, x) -> op 0x0e; vec var xs; var x
      | Return -> op 0x0f
      | Call x -> op 0x10; var x
      | CallIndirect x -> op 0x11; var x; u8 0x00

      | Drop -> op 0x1a
      | Select -> op 0x1b

      | LocalGet x -> op 0x20; var x
      | LocalSet x -> op 0x21; var x
      | LocalTee x -> op 0x22; var x
      | GlobalGet x -> op 0x23; var x
      | GlobalSet x -> op 0x24; var x

      | Load ({ty = I32Type; sz = None; _} as mo) -> op 0x28; memop mo
      | Load ({ty = I64Type; sz = None; _} as mo) -> op 0x29; memop mo
      | Load ({ty = F32Type; sz = None; _} as mo) -> op 0x2a; memop mo
      | Load ({ty = F64Type; sz = None; _} as mo) -> op 0x2b; memop mo
      | Load ({ty = I32Type; sz = Some (Pack8, SX); _} as mo) ->
        op 0x2c; memop mo
      | Load ({ty = I32Type; sz = Some (Pack8, ZX); _} as mo) ->
        op 0x2d; memop mo
      | Load ({ty = I32Type; sz = Some (Pack16, SX); _} as mo) ->
        op 0x2e; memop mo
      | Load ({ty = I32Type; sz = Some (Pack16, ZX); _} as mo) ->
        op 0x2f; memop mo
      | Load {ty = I32Type; sz = Some (Pack32, _); _} ->
        assert false
      | Load ({ty = I64Type; sz = Some (Pack8, SX); _} as mo) ->
        op 0x30; memop mo
      | Load ({ty = I64Type; sz = Some (Pack8, ZX); _} as mo) ->
        op 0x31; memop mo
      | Load ({ty = I64Type; sz = Some (Pack16, SX); _} as mo) ->
        op 0x32; memop mo
      | Load ({ty = I64Type; sz = Some (Pack16, ZX); _} as mo) ->
        op 0x33; memop mo
      | Load ({ty = I64Type; sz = Some (Pack32, SX); _} as mo) ->
        op 0x34; memop mo
      | Load ({ty = I64Type; sz = Some (Pack32, ZX); _} as mo) ->
        op 0x35; memop mo
      | Load {ty = F32Type | F64Type; sz = Some _; _} ->
        assert false

      | Store ({ty = I32Type; sz = None; _} as mo) -> op 0x36; memop mo
      | Store ({ty = I64Type; sz = None; _} as mo) -> op 0x37; memop mo
      | Store ({ty = F32Type; sz = None; _} as mo) -> op 0x38; memop mo
      | Store ({ty = F64Type; sz = None; _} as mo) -> op 0x39; memop mo
      | Store ({ty = I32Type; sz = Some Pack8; _} as mo) -> op 0x3a; memop mo
      | Store ({ty = I32Type; sz = Some Pack16; _} as mo) -> op 0x3b; memop mo
      | Store {ty = I32Type; sz = Some Pack32; _} -> assert false
      | Store ({ty = I64Type; sz = Some Pack8; _} as mo) -> op 0x3c; memop mo
      | Store ({ty = I64Type; sz = Some Pack16; _} as mo) -> op 0x3d; memop mo
      | Store ({ty = I64Type; sz = Some Pack32; _} as mo) -> op 0x3e; memop mo
      | Store {ty = F32Type | F64Type; sz = Some _; _} -> assert false

      | MemorySize -> op 0x3f; u8 0x00
      | MemoryGrow -> op 0x40; u8 0x00

      | Const {it = I32 c; _} -> op 0x41; vs32 c
      | Const {it = I64 c; _} -> op 0x42; vs64 c
      | Const {it = F32 c; _} -> op 0x43; f32 c
      | Const {it = F64 c; _} -> op 0x44; f64 c

      | Test (I32 I32Op.Eqz) -> op 0x45
      | Test (I64 I64Op.Eqz) -> op 0x50
      | Test (F32 _) -> assert false
      | Test (F64 _) -> assert false

      | Compare (I32 I32Op.Eq) -> op 0x46
      | Compare (I32 I32Op.Ne) -> op 0x47
      | Compare (I32 I32Op.LtS) -> op 0x48
      | Compare (I32 I32Op.LtU) -> op 0x49
      | Compare (I32 I32Op.GtS) -> op 0x4a
      | Compare (I32 I32Op.GtU) -> op 0x4b
      | Compare (I32 I32Op.LeS) -> op 0x4c
      | Compare (I32 I32Op.LeU) -> op 0x4d
      | Compare (I32 I32Op.GeS) -> op 0x4e
      | Compare (I32 I32Op.GeU) -> op 0x4f

      | Compare (I64 I64Op.Eq) -> op 0x51
      | Compare (I64 I64Op.Ne) -> op 0x52
      | Compare (I64 I64Op.LtS) -> op 0x53
      | Compare (I64 I64Op.LtU) -> op 0x54
      | Compare (I64 I64Op.GtS) -> op 0x55
      | Compare (I64 I64Op.GtU) -> op 0x56
      | Compare (I64 I64Op.LeS) -> op 0x57
      | Compare (I64 I64Op.LeU) -> op 0x58
      | Compare (I64 I64Op.GeS) -> op 0x59
      | Compare (I64 I64Op.GeU) -> op 0x5a

      | Compare (F32 F32Op.Eq) -> op 0x5b
      | Compare (F32 F32Op.Ne) -> op 0x5c
      | Compare (F32 F32Op.Lt) -> op 0x5d
      | Compare (F32 F32Op.Gt) -> op 0x5e
      | Compare (F32 F32Op.Le) -> op 0x5f
      | Compare (F32 F32Op.Ge) -> op 0x60

      | Compare (F64 F64Op.Eq) -> op 0x61
      | Compare (F64 F64Op.Ne) -> op 0x62
      | Compare (F64 F64Op.Lt) -> op 0x63
      | Compare (F64 F64Op.Gt) -> op 0x64
      | Compare (F64 F64Op.Le) -> op 0x65
      | Compare (F64 F64Op.Ge) -> op 0x66

      | Unary (I32 I32Op.Clz) -> op 0x67
      | Unary (I32 I32Op.Ctz) -> op 0x68
      | Unary (I32 I32Op.Popcnt) -> op 0x69

      | Unary (I64 I64Op.Clz) -> op 0x79
      | Unary (I64 I64Op.Ctz) -> op 0x7a
      | Unary (I64 I64Op.Popcnt) -> op 0x7b

      | Unary (F32 F32Op.Abs) -> op 0x8b
      | Unary (F32 F32Op.Neg) -> op 0x8c
      | Unary (F32 F32Op.Ceil) -> op 0x8d
      | Unary (F32 F32Op.Floor) -> op 0x8e
      | Unary (F32 F32Op.Trunc) -> op 0x8f
      | Unary (F32 F32Op.Nearest) -> op 0x90
      | Unary (F32 F32Op.Sqrt) -> op 0x91

      | Unary (F64 F64Op.Abs) -> op 0x99
      | Unary (F64 F64Op.Neg) -> op 0x9a
      | Unary (F64 F64Op.Ceil) -> op 0x9b
      | Unary (F64 F64Op.Floor) -> op 0x9c
      | Unary (F64 F64Op.Trunc) -> op 0x9d
      | Unary (F64 F64Op.Nearest) -> op 0x9e
      | Unary (F64 F64Op.Sqrt) -> op 0x9f

      | Binary (I32 I32Op.Add) -> op 0x6a
      | Binary (I32 I32Op.Sub) -> op 0x6b
      | Binary (I32 I32Op.Mul) -> op 0x6c
      | Binary (I32 I32Op.DivS) -> op 0x6d
      | Binary (I32 I32Op.DivU) -> op 0x6e
      | Binary (I32 I32Op.RemS) -> op 0x6f
      | Binary (I32 I32Op.RemU) -> op 0x70
      | Binary (I32 I32Op.And) -> op 0x71
      | Binary (I32 I32Op.Or) -> op 0x72
      | Binary (I32 I32Op.Xor) -> op 0x73
      | Binary (I32 I32Op.Shl) -> op 0x74
      | Binary (I32 I32Op.ShrS) -> op 0x75
      | Binary (I32 I32Op.ShrU) -> op 0x76
      | Binary (I32 I32Op.Rotl) -> op 0x77
      | Binary (I32 I32Op.Rotr) -> op 0x78

      | Binary (I64 I64Op.Add) -> op 0x7c
      | Binary (I64 I64Op.Sub) -> op 0x7d
      | Binary (I64 I64Op.Mul) -> op 0x7e
      | Binary (I64 I64Op.DivS) -> op 0x7f
      | Binary (I64 I64Op.DivU) -> op 0x80
      | Binary (I64 I64Op.RemS) -> op 0x81
      | Binary (I64 I64Op.RemU) -> op 0x82
      | Binary (I64 I64Op.And) -> op 0x83
      | Binary (I64 I64Op.Or) -> op 0x84
      | Binary (I64 I64Op.Xor) -> op 0x85
      | Binary (I64 I64Op.Shl) -> op 0x86
      | Binary (I64 I64Op.ShrS) -> op 0x87
      | Binary (I64 I64Op.ShrU) -> op 0x88
      | Binary (I64 I64Op.Rotl) -> op 0x89
      | Binary (I64 I64Op.Rotr) -> op 0x8a

      | Binary (F32 F32Op.Add) -> op 0x92
      | Binary (F32 F32Op.Sub) -> op 0x93
      | Binary (F32 F32Op.Mul) -> op 0x94
      | Binary (F32 F32Op.Div) -> op 0x95
      | Binary (F32 F32Op.Min) -> op 0x96
      | Binary (F32 F32Op.Max) -> op 0x97
      | Binary (F32 F32Op.CopySign) -> op 0x98

      | Binary (F64 F64Op.Add) -> op 0xa0
      | Binary (F64 F64Op.Sub) -> op 0xa1
      | Binary (F64 F64Op.Mul) -> op 0xa2
      | Binary (F64 F64Op.Div) -> op 0xa3
      | Binary (F64 F64Op.Min) -> op 0xa4
      | Binary (F64 F64Op.Max) -> op 0xa5
      | Binary (F64 F64Op.CopySign) -> op 0xa6

      | Convert (I32 I32Op.ExtendSI32) -> assert false
      | Convert (I32 I32Op.ExtendUI32) -> assert false
      | Convert (I32 I32Op.WrapI64) -> op 0xa7
      | Convert (I32 I32Op.TruncSF32) -> op 0xa8
      | Convert (I32 I32Op.TruncUF32) -> op 0xa9
      | Convert (I32 I32Op.TruncSF64) -> op 0xaa
      | Convert (I32 I32Op.TruncUF64) -> op 0xab
      | Convert (I32 I32Op.ReinterpretFloat) -> op 0xbc

      | Convert (I64 I64Op.ExtendSI32) -> op 0xac
      | Convert (I64 I64Op.ExtendUI32) -> op 0xad
      | Convert (I64 I64Op.WrapI64) -> assert false
      | Convert (I64 I64Op.TruncSF32) -> op 0xae
      | Convert (I64 I64Op.TruncUF32) -> op 0xaf
      | Convert (I64 I64Op.TruncSF64) -> op 0xb0
      | Convert (I64 I64Op.TruncUF64) -> op 0xb1
      | Convert (I64 I64Op.ReinterpretFloat) -> op 0xbd

      | Convert (F32 F32Op.ConvertSI32) -> op 0xb2
      | Convert (F32 F32Op.ConvertUI32) -> op 0xb3
      | Convert (F32 F32Op.ConvertSI64) -> op 0xb4
      | Convert (F32 F32Op.ConvertUI64) -> op 0xb5
      | Convert (F32 F32Op.PromoteF32) -> assert false
      | Convert (F32 F32Op.DemoteF64) -> op 0xb6
      | Convert (F32 F32Op.ReinterpretInt) -> op 0xbe

      | Convert (F64 F64Op.ConvertSI32) -> op 0xb7
      | Convert (F64 F64Op.ConvertUI32) -> op 0xb8
      | Convert (F64 F64Op.ConvertSI64) -> op 0xb9
      | Convert (F64 F64Op.ConvertUI64) -> op 0xba
      | Convert (F64 F64Op.PromoteF32) -> op 0xbb
      | Convert (F64 F64Op.DemoteF64) -> assert false
      | Convert (F64 F64Op.ReinterpretInt) -> op 0xbf

    let const c =
      list (instr' ignore) c.it; end_ ()

    (* Sections *)

    let section id f x needed =
      if needed then begin
        u8 id;
        let g = gap32 () in
        let p = pos s in
        f x;
        patch_gap32 g (pos s - p)
      end

    let custom_section name f x needed =
      section 0 (fun x ->
        string name;
        f x
      ) x needed

    (* Type section *)
    let type_ t = func_type t.it

    let type_section ts =
      section 1 (vec type_) ts (ts <> [])

    (* Import section *)
    let import_desc d =
      match d.it with
      | FuncImport x -> u8 0x00; var x
      | TableImport t -> u8 0x01; table_type t
      | MemoryImport t -> u8 0x02; memory_type t
      | GlobalImport t -> u8 0x03; global_type t

    let import im =
      let {module_name; item_name; idesc} = im.it in
      name module_name; name item_name; import_desc idesc

    let import_section ims =
      section 2 (vec import) ims (ims <> [])

    (* Function section *)
    let func f = var f.it.ftype

    let func_section fs =
      section 3 (vec func) fs (fs <> [])

    (* Table section *)
    let table tab =
      let {ttype} = tab.it in
      table_type ttype

    let table_section tabs =
      section 4 (vec table) tabs (tabs <> [])

    (* Memory section *)
    let memory mem =
      let {mtype} = mem.it in
      memory_type mtype

    let memory_section mems =
      section 5 (vec memory) mems (mems <> [])

    (* Global section *)
    let global g =
      let {gtype; value} = g.it in
      global_type gtype; const value

    let global_section gs =
      section 6 (vec global) gs (gs <> [])

    (* Export section *)
    let export_desc d =
      match d.it with
      | FuncExport x -> u8 0; var x
      | TableExport x -> u8 1; var x
      | MemoryExport x -> u8 2; var x
      | GlobalExport x -> u8 3; var x

    let export ex =
      let {name = n; edesc} = ex.it in
      name n; export_desc edesc

    let export_section exs =
      section 7 (vec export) exs (exs <> [])

    (* Start section *)
    let start_section xo =
      section 8 (opt var) xo (xo <> None)

    (* Code section *)
    let compress ts =
      let combine t = function
        | (t', n) :: ts when t = t' -> (t, n + 1) :: ts
        | ts -> (t, 1) :: ts
      in List.fold_right combine ts []

    let local (t, n) = len n; value_type t

    let (here_dir, asset_dir) = (0, 1) (* reversed indices in dir_names, below *)
    let source_names =
      ref [ "prim", (Promise.make (), asset_dir)
          ; "rts.wasm", (Promise.make (), asset_dir) ] (* make these appear last in .debug_line file_name_entries *)
    let dir_names = (* dito, but reversed: 6.2.4.1 Standard Content Descriptions *)
      ref [ "<moc-asset>", (Promise.make (), asset_dir)
          ; Filename.dirname "", (Promise.make (), here_dir) ]
    let source_path_indices = ref (List.map (fun (p, (_, i)) -> p, i) !source_names)
    let add_source_name =
      let source_adder dir_index _ = Promise.make (), dir_index in
      let add_source_path_index (_, _) = function
        | "" -> assert false
        | str ->
          ignore (add_string (function [] -> assert false | (_, i) :: _ -> i + 1) source_path_indices str) in
      function
      | "" -> ()
      | ("prelude" | "prim" | "rts.wasm") as asset ->
        add_source_path_index (add_string (source_adder asset_dir) source_names asset) asset
      | path ->
        let dir, basename = Filename.(dirname path, basename path) in
        let _, dir_index = add_string (function [] -> assert false | (_, (_, i)) :: _ -> Promise.make (), i + 1) dir_names dir in
        let promise = add_string (source_adder dir_index) source_names basename in
        add_source_path_index promise path

    let code f =
      let {locals; body; _} = f.it in
      let g = gap32 () in
      let p = pos s in
      vec local (compress locals);
      let instr_notes = ref Instrs.empty in
      let note i =
        if not (dwarf_like i.at) then
          (if i.at.left.file = "wasmtime/tests/debug/testsuite/fib-wasm.mo" then Printf.printf "NOTING origin: 0x%x pos: 0x%x  (%s:%d:%d)\n" p (pos s) i.at.left.file i.at.left.line i.at.left.column;
           modif instr_notes (Instrs.add (pos s, i.at.left));
           ignore (add_source_name i.at.left.file)
          ) in
      list (instr' note) body;
      end_ ();
      sequence_number := 1 + !sequence_number;
      let sequence_end = pos s in
      patch_gap32 g (sequence_end - p);
      modif sequence_bounds (Sequ.add (p, !instr_notes, sequence_end))

    let code_section_start = ref 0
    let code_section fs =
      section 10 (fun fs -> code_section_start := pos s; vec code fs) fs (fs <> [])

    (* Element section *)
    let segment dat seg =
      let {index; offset; init} = seg.it in
      var index; const offset; dat init

    let table_segment seg =
      segment (vec var) seg

    let elem_section elems =
      section 9 (vec table_segment) elems (elems <> [])

    (* Data section *)
    let memory_segment seg =
      segment string seg

    let data_section data =
      section 11 (vec memory_segment) data (data <> [])

    (* Name section *)

    let assoc_list : 'a. ('a -> unit) -> (int32 * 'a) list -> unit = fun f xs ->
      vec (fun (li, x) -> vu32 li; f x)
          (List.sort (fun (i1,_) (i2,_) -> compare i1 i2) xs)

    let name_section_body (ns : name_section) =
      (* module name section *)
      section 0 (opt string) ns.module_ (ns.module_ <> None);
      (* function names section *)
      section 1 (assoc_list string) ns.function_names  (ns.function_names <> []);
      (* locals names section *)
      section 2 (assoc_list (assoc_list string)) ns.locals_names  (ns.locals_names <> [])

    let name_section ns =
      custom_section "name" name_section_body ns
        (ns.module_ <> None || ns.function_names <> [] || ns.locals_names <> [])

    let uleb128 n = vu64 (Int64.of_int n)
    let sleb128 n = vs64 (Int64.of_int n)
    let close_section () = u8 0x00
    let write16 = Buffer.add_int16_le s.buf
    let write32 i = Buffer.add_int32_le s.buf (Int32.of_int i)
    let zero_terminated str = put_string s str; u8 0
    let vec_uleb128 el = vec_by uleb128 el
    let writeBlock1 str = let len = String.length str in assert (len < 256); u8 len; put_string s str
    let writeBlockLEB str = let len = String.length str in assert (len < 256); uleb128 len; put_string s str

    let debug_abbrev_section () =
      let tag (t, ch, kvs) =
        uleb128 (t land 0xFFFF); u8 ch;
        assert (kvs <> []); (* these run risk of dead-code elimination *)
        List.iter (fun (k, v) -> uleb128 k; uleb128 v) kvs in
      let abbrev i abs = uleb128 (i + 1); tag abs; close_section (); close_section () in
      let section_body abs = List.iteri abbrev abs; close_section () in
      custom_section ".debug_abbrev" section_body Abbreviation.abbreviations true

    let rangelists = Promise.make ()

    (* dw_FORM writers *)
    let writeForm : int -> dwarf_artifact -> unit =
      let open Dwarf5 in
      function
      | f when dw_FORM_strp = f ->
        begin function
          | StringAttribute (attr, str) -> write32 (add_dwarf_string str)
          | _ -> failwith "dw_FORM_strp"
        end
      | f when dw_FORM_data1 = f ->
        begin function
          | IntAttribute (attr, i) -> u8 i
          | _ -> failwith "dw_FORM_data1"
        end
      | f when dw_FORM_data2 = f ->
        begin function
          | IntAttribute (attr, i) -> write16 i
          | _ -> failwith "dw_FORM_data2"
        end
      | f when dw_FORM_data4 = f ->
        begin function
          | IntAttribute (attr, i) -> write32 i
          | _ -> failwith "dw_FORM_data4"
        end
      | f when dw_FORM_addr = f ->
        begin function
          | IntAttribute (attr, i) -> write32 i
          | _ -> failwith "dw_FORM_addr"
        end
      | f when dw_FORM_addrx = f ->
        begin function
          | IntAttribute (attr, i) -> uleb128 i
          | _ -> failwith "dw_FORM_addrx"
        end
      | f when dw_FORM_ref_udata = f ->
        begin function
          | IntAttribute (attr, i) -> Printf.printf "LOOKING FOR %d REF\n" i; uleb128 (Promise.value (References.find i !dw_references))
          | _ -> failwith "dw_FORM_ref_udata"
        end
      | f when dw_FORM_sec_offset = f ->
        begin function
          | IntAttribute (attr, i) -> write32 i
          | FunctionsAttribute attr ->
            write32 (Promise.value rangelists)
          | _ -> failwith "dw_FORM_sec_offset"
        end
      | f when dw_FORM_block1 = f ->
        begin function
          | StringAttribute (attr, str) -> writeBlock1 str
          | _ -> failwith "dw_FORM_block1"
        end
      | f when dw_FORM_exprloc = f ->
        begin function
          | StringAttribute (attr, str) -> writeBlockLEB str
          | _ -> failwith "dw_FORM_exprloc"
        end
      | f when dw_FORM_flag = f ->
        begin function
          | IntAttribute (attr, b) -> u8 b
          | _ -> failwith "dw_FORM_flag"
        end
      | f when dw_FORM_flag_present = f ->
        begin function
          | IntAttribute (attr, 0) -> failwith "dw_FORM_flag_present with false"
          | IntAttribute (attr, _) -> ()
          | _ -> failwith "dw_FORM_flag_present"
        end
      | _ -> failwith("cannot write form")

    let info_section_start = ref 0
    let subprogram_sizes = Promise.make ()

    let rec writeTag = function
      | Tag (r, t, contentsRevd) ->
        Printf.printf "WRITING TAG: 0x%x\n" t;
        begin match r with
        | Some refi -> Printf.printf "FULFILLING: %d\n" refi; Promise.fulfill (References.find refi !dw_references) (pos s - !info_section_start)
        | None -> assert (t <> Dwarf5.dw_TAG_base_type)
        end;
        let contents = List.rev contentsRevd in
        let isTag (t', _, _) = t = t' in
        let (_, has_children, forms) = List.find isTag Abbreviation.abbreviations in
        let pairing (attr, form) = function
          | Tag _ -> failwith "Attribute expected"
          | RangeAttribute (a, r) -> if attr <> a then Printf.printf "attr: 0x%x = a: 0x%x (in TAG 0x%x)\n" attr a t;assert (attr = a); writeForm form (IntAttribute (a, Array.get (Promise.value subprogram_sizes) r))
          | StringAttribute (a, path) when a = Dwarf5.dw_AT_decl_file -> if attr = a then Printf.printf "DATA1 attr: 0x%x = a: 0x%x (in TAG 0x%x) PATH: %s  ULT: (%s, %d)\n" attr a t path    (fst (List.hd !source_path_indices)) (snd (List.hd !source_path_indices)) ;assert (attr = a); writeForm form (IntAttribute (a, List.(snd (hd !source_path_indices) - assoc path !source_path_indices)))
          | IntAttribute (a, _) as art -> if attr <> a then Printf.printf "attr: 0x%x = a: 0x%x (in TAG 0x%x)\n" attr a t;assert (attr = a); writeForm form art
          | StringAttribute (a, _) as art -> assert (attr = a); writeForm form art
          | FunctionsAttribute a as art -> (* Printf.printf "attr: %x = a: %x \n" attr a ;  *)assert (attr = a); writeForm form art in
        let rec indexOf cnt = function
          | h :: t when isTag h -> cnt
          | _ :: t -> indexOf (cnt + 1) t
          | _ -> failwith "not encountered" in
        uleb128 (indexOf 1 Abbreviation.abbreviations);
        let nested_tags, attrs = List.partition (function Tag _ -> true | _ -> false) contents in

        List.iter2 pairing forms attrs;
        List.iter writeTag nested_tags;
        if has_children <> 0 then close_section ()
      | _ -> failwith "Tag expected"

    let unit f =
      let dw_gap32 () = let p = pos s in write32 0x0; p in
      let dw_patch_gap32 p n =
        let lsb i = Char.chr (i land 0xff) in
        patch s p (lsb n);
        patch s (p + 1) (lsb (n lsr 8));
        patch s (p + 2) (lsb (n lsr 16));
        patch s (p + 3) (lsb (n lsr 24)) in
      let g = dw_gap32 () in (* unit_length *)
      let p = pos s in
      f g; dw_patch_gap32 g (pos s - p)

    let debug_info_section () =
      let section_body abs =
        unit(fun info_start ->
            write16 0x0005; (* version *)
            u8 Dwarf5.dw_UT_compile; (* unit_type *)
            u8 4; (* address_size *)
            write32 0x0000; (* debug_abbrev_offset *)
            info_section_start := info_start;

            match !dwarf_tags with
            | [toplevel] -> writeTag toplevel
            | _ -> failwith "expected one toplevel tag"
        ) in
      custom_section ".debug_info" section_body dwarf_tags true

    let debug_strings_section dss =
      let rec debug_strings_section_body = function
        | [] -> ()
        | (h, _) :: t -> debug_strings_section_body t; zero_terminated h
      in
      custom_section ".debug_str" debug_strings_section_body dss (dss <> [])


    let debug_addr_section seqs =
      let debug_addr_section_body seqs =
        unit(fun start ->
            write16 0x0005; (* version *)
            u8 4; (* addr_size *)
            u8 0; (* segment_selector_size *)
            let write_addr (st, _, _) =
              let rel addr = addr - !code_section_start in
              write32 (rel st)
            in
            Sequ.iter write_addr seqs;
        )
      in
      custom_section ".debug_addr" debug_addr_section_body seqs (not (Sequ.is_empty seqs))


    (* 7.28 Range List Table *)
    let debug_rnglists_section sequence_bounds =
      let index = ref 0 in
      let debug_rnglists_section_body () =
        unit(fun start ->
            write16 0x0005; (* version *)
            u8 4; (* address_size *)
            u8 0; (* segment_selector_size *)
            write32 0; (* offset_entry_count *)

            Promise.fulfill rangelists (pos s - start);
            Sequ.iter (fun (st, _, en) ->
                u8 Dwarf5.dw_RLE_startx_length;
                uleb128 !index;
                index := !index + 1;
                uleb128 (en - st))
              sequence_bounds;
            u8 Dwarf5.dw_RLE_end_of_list;

            (* extract the subprogram sizes to an array *)
            Promise.fulfill subprogram_sizes (Array.of_seq (Seq.map (fun (st, _, en) -> en - st) (Sequ.to_seq sequence_bounds)))
        );

        in
      custom_section ".debug_rnglists" debug_rnglists_section_body () true

    let debug_line_str_section () =
      let rec string fulfill = function
        | [] -> ()
        | (h, p) :: t -> fulfill p; zero_terminated h; string fulfill t in
      let debug_line_strings_section_body (dirs, sources) =
        let start = pos s in
        let promised_pos = string (fun (p, _) -> Promise.fulfill p (pos s - start)) in
        promised_pos dirs;
        promised_pos sources in
      custom_section ".debug_line_str" debug_line_strings_section_body (!dir_names, !source_names) true

    let debug_line_section fs =
      let debug_line_section_body () =

        unit(fun start ->
            write16 0x0005;
            u8 4;
            u8 0; (* segment_selector_size *)
            unit(fun _ ->
                u8 1; (* min_inst_length *)
                u8 1; (* max_ops_per_inst *)
                u8 (if Dwarf5.Machine.default_is_stmt then 1 else 0); (* default_is_stmt *)
                u8 0; (* line_base *)
                u8 12; (* line_range *)
                u8 13; (* opcode_base *)
                (*
standard_opcode_lengths[DW_LNS_copy] = 0
standard_opcode_lengths[DW_LNS_advance_pc] = 1
standard_opcode_lengths[DW_LNS_advance_line] = 1
standard_opcode_lengths[DW_LNS_set_file] = 1
standard_opcode_lengths[DW_LNS_set_column] = 1
standard_opcode_lengths[DW_LNS_negate_stmt] = 0
standard_opcode_lengths[DW_LNS_set_basic_block] = 0
standard_opcode_lengths[DW_LNS_const_add_pc] = 0
standard_opcode_lengths[DW_LNS_fixed_advance_pc] = 1
standard_opcode_lengths[DW_LNS_set_prologue_end] = 0
standard_opcode_lengths[DW_LNS_set_epilogue_begin] = 0
standard_opcode_lengths[DW_LNS_set_isa] = 1
                 *)
                let open List in
                iter u8 [0; 1; 1; 1; 1; 0; 0; 0; 1; 0; 0; 1];

                let format (l, f) = uleb128 l; uleb128 f in
                let vec_format = vec_by u8 format in

                (* directory_entry_format_count, directory_entry_formats *)
                vec_format Dwarf5.[dw_LNCT_path, dw_FORM_line_strp];

                (* directories_count, directories *)
                vec_uleb128 write32 (rev_map (fun (_, (p, _)) -> Promise.value p) !dir_names);

                (* file_name_entry_format_count, file_name_entry_formats *)
                vec_format Dwarf5.[dw_LNCT_path, dw_FORM_line_strp; dw_LNCT_directory_index, dw_FORM_udata];

                (* The first entry in the sequence is the primary source file whose file name exactly
                   matches that given in the DW_AT_name attribute in the compilation unit debugging
                   information entry. This is ensured by the heuristics, that the last noted source file
                   will be placed at position 0 in the table *)
                vec_uleb128
                  (fun (pos, indx) -> write32 pos; uleb128 indx)
                  (map (fun (_, (p, dir_indx)) -> Promise.value p, dir_indx) !source_names);
            );

            (* build the statement loc -> addr map *)
            let statement_positions = !statement_positions in
            let module StmtsAt = Map.Make (struct type t = Wasm.Source.pos let compare = compare end) in
            let statements_at = StmtsAt.of_seq (Seq.map (fun (k, v) -> v, k) (Instrs.to_seq statement_positions)) in
            let is_statement_at (addr, loc) =
              match StmtsAt.find_opt loc statements_at with
              | Some addr' when  addr =  addr' -> true
              | _ -> false in

            (* generate the line section *)
            let code_start = !code_section_start in
            let rel addr = addr - code_start in
            let source_indices = !source_path_indices in

            let mapping (addr, {file; line; column} as loc) : Dwarf5.Machine.state =
              if file = "wasmtime/tests/debug/testsuite/fib-wasm.mo" then (Printf.printf "BINGO CODE START: 0x%x  OFFS 0x%x REL 0x%x fib-wasm.mo:%d:%d\n" code_start addr (rel addr) line column);

              let file' = List.(snd (hd source_indices) - assoc (if file = "" then "prim" else file) source_indices) in
              let stmt = Instrs.mem loc statement_positions || is_statement_at loc (* FIXME TODO: why ||? *) in
              rel addr, (file', line, column + 1), 0, (stmt, false, false, false) in

            let joining (prg, state) state' : int list * Dwarf5.Machine.state =
              (* FIXME: quadratic *)
              prg @ Dwarf5.Machine.infer state state', state'
            in

            let sequence (sta, notes, en) =
              let start, ending = rel sta, rel en in
              Printf.printf "LINES::::  SEQUENCE start/END    ADDR: 0x%x - 0x%x\n" start ending;
              Instrs.iter (fun (addr, {file; line; column} as instr) -> Printf.printf "\tLINES::::  Instr    ADDR: 0x%x - (%s(=%d):%d:%d)    %s\n" (rel addr) file List.(snd (hd source_indices) - assoc (if file = "" then "prim" else file) source_indices) line column (if Instrs.mem instr statement_positions then "is_stmt" else "")) notes;
           
              let notes_seq = Instrs.to_seq notes in
              (* Decorate first instr, and prepend start address, non-statement (FIXME: clang says it *is* an instruction) *)
              let start_state = let _, loc, d, (_, bb, pe, eb) = Dwarf5.Machine.start_state in start, loc, d, (false, bb, pe, eb) in
              let states_seq () =
                let open Seq in
                match map mapping notes_seq () with
                | Cons ((a, _, _, _), _) when a = start -> failwith "at start already an instruction?"
                | Cons ((a, l, d, (stm, bb, _, epi)), t) ->
                  let start_state' = let a, _, d, f  = start_state in a, l, d, f in
                  Cons (start_state', fun () -> Cons ((a, l, d, (stm, bb, false, epi)), t))
                | Nil -> Cons (start_state, fun () -> Nil)
              in

              let prg, (addr, _, _, (stm, _, _, _)) = Seq.fold_left joining Dwarf5.([], Machine.start_state) states_seq in
              Dwarf5.(Machine.moves u8 uleb128 sleb128 write32
                        (prg @ [dw_LNS_advance_pc; ending - addr - 1]
                             @ (if stm then [] else [dw_LNS_negate_stmt])
                             @ [dw_LNS_set_epilogue_begin; dw_LNS_copy;
                                dw_LNS_advance_pc; 1; dw_LNS_negate_stmt; - dw_LNE_end_sequence]))
            in
            Sequ.iter sequence !sequence_bounds
        )
      in
      custom_section ".debug_line" debug_line_section_body () (fs <> [])


    (* 7.29 Location List Table *)
    let debug_loclists_section () =
      let rec write_loclist =
        let open Dwarf5 in
        let open Location in
        function
        | op :: n :: r when dw_OP_WASM_local = op ->
          u8 dw_OP_WASM_location; u8 0x00; uleb128 n; write_loclist r
        | op :: n :: r when dw_OP_WASM_global = op ->
          u8 dw_OP_WASM_location; u8 0x01; uleb128 n; write_loclist r
        | op :: n :: r when dw_OP_WASM_stack = op ->
          u8 dw_OP_WASM_location; u8 0x02; uleb128 n; write_loclist r
        | _ -> failwith "write_loclist" in
      let debug_loclists_section_body () =
        write16 0x0005; (* version *)
        u8 4; (* address_size *)
        u8 0; (* segment_selector_size *)
        write32 0; (* offset_entry_count *)

      in
      custom_section ".debug_loclists" debug_loclists_section_body () true

    (* Module *)

    let module_ (em : extended_module) =
      let m = em.module_ in

      u32 0x6d736100l;
      u32 version;
      (* no use-case for encoding dylink section yet, but here would be the place *)
      assert (em.dylink = None);
      type_section m.types;
      import_section m.imports;
      func_section m.funcs;
      table_section m.tables;
      memory_section m.memories;
      global_section m.globals;
      export_section m.exports;
      start_section m.start;
      elem_section m.elems;
      code_section m.funcs;
      data_section m.data;
      (* other optional sections *)
      name_section em.name;
      debug_abbrev_section ();
      debug_addr_section !sequence_bounds;
      debug_rnglists_section !sequence_bounds;
      (*debug_loclists_section (); NOT YET*)
      debug_line_str_section ();
      debug_line_section m.funcs;
      debug_info_section ();
      debug_strings_section !dwarf_strings
  end
  in E.module_ em;

  let mappings = Buffer.contents map in
  let n = max 0 ((String.length mappings) - 1) in
  let json : Yojson.Basic.t = `Assoc [
    ("version", `Int 3);
    ("sources", `List ( List.map (fun x -> `String x) !sources ) );
    ("sourcesContent", `List ( List.map (fun x -> if x = "" then `Null else `String x) !sourcesContent ) );
    ("mappings", `String (String.sub mappings 0 n) )
  ] in

  (Yojson.Basic.to_string json, to_string s)
