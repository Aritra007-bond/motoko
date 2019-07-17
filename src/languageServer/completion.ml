open As_types
open As_frontend
module Lsp_t = Lsp.Lsp_t

type ide_decl =
  | ValueDecl of string * Type.typ
  | TypeDecl of string * Type.typ

module Index = Map.Make(String)
type completion_index = (ide_decl list) Index.t

let string_of_list f xs =
  List.map f xs
  |> String.concat "; "
  |> fun x -> "[ " ^ x ^ " ]"

let template_of_ide_decl decl =
  let supply = ref 0 in
  let fresh () = supply := !supply + 1; string_of_int !supply in
  match decl with
  | ValueDecl (lbl, ty) ->
     (match ty with
      | Type.Func(_, _, binds, ty_list1, ty_list2) ->
         let ty_args =
           binds
           |> List.map (fun Type.{ var = var; bound = bound} ->
                  Printf.sprintf "${%s:%s}" (fresh ()) var)
           |> String.concat ", " in
         let args =
           ty_list1
           |> List.map (fun _ -> Printf.sprintf "$%s" (fresh ()))
           |> String.concat ", " in
         let ty_args = if ty_args = "" then "" else "<" ^ ty_args ^ ">" in
         Printf.sprintf "%s%s(%s)" lbl ty_args args
      | _ -> lbl)
  | TypeDecl (lbl, ty) ->
     lbl

let lbl_of_ide_decl (d : ide_decl) : string =
  match d with
  | ValueDecl (lbl, _) -> lbl
  | TypeDecl (lbl, _) -> lbl

let item_of_ide_decl (d : ide_decl) : Lsp_t.completion_item =
  let tmpl = template_of_ide_decl d in
  match d with
  | ValueDecl (lbl, ty) ->
     Lsp_t.{
        completion_item_label = lbl;
        completion_item_kind = 3;
        completion_item_insertText = tmpl;
        completion_item_insertTextFormat = 2;
        completion_item_detail = Some(Type.string_of_typ ty);
     }
  | TypeDecl (lbl, ty) ->
     Lsp_t.{
        completion_item_label = lbl;
        completion_item_kind = 7;
        completion_item_insertText = tmpl;
        completion_item_insertTextFormat = 2;
        completion_item_detail = Some(Type.string_of_typ ty);
     }

let string_of_ide_decl = function
  | ValueDecl (lbl, ty) ->
     "ValueDecl(" ^ String.escaped lbl ^ ", " ^ Type.string_of_typ ty ^ ")"
  | TypeDecl (lbl, ty) ->
     "TypeDecl(" ^ String.escaped lbl ^ ", " ^ Type.string_of_typ ty ^ ")"

let lib_files () : string list =
  let lib_dir = "lib" in
  Sys.readdir lib_dir
  |> Array.to_list
  |> List.filter (fun file -> String.equal (Filename.extension file) ".as")
  |> List.map (fun file -> Filename.concat lib_dir file)

let read_single_module_lib (ty: Type.typ): ide_decl list option =
  match ty with
  | Type.Obj (Type.Module, fields) ->
     fields
     |> List.map (fun Type.{ lab = lab; typ = typ } -> ValueDecl (lab, typ))
     |> Lib.Option.some
  | _ -> None

let make_index (): completion_index =
  let (libraries, scope) =
    Diag.run
      (Pipeline.chase_imports
         Pipeline.initial_stat_env
         (Pipeline__.Resolve_import.S.of_list (lib_files ()))) in
  Type.Env.fold
    (fun path ty acc ->
      Index.add
        path
        (ty
         |> read_single_module_lib
         |> Lib.Fun.flip Lib.Option.get [])
        acc)
    scope.Scope.lib_env
    Index.empty

let string_of_index index =
  Index.bindings index
  |> string_of_list
       (fun (path, decls) ->
         path
         ^ " =>\n    "
         ^ string_of_list string_of_ide_decl decls
         ^ "\n")

let import_relative_to_project_root root module_path dependency =
  match Pipeline__.File_path.relative_to root module_path with
  | None -> None
  | Some root_to_module ->
     root_to_module
     |> Filename.dirname
     |> Lib.Fun.flip Filename.concat dependency
     |> Pipeline__.File_path.normalise
     |> Lib.Option.some

(* Given the source of a module, figure out under what names what
   modules have been imported. Normalizes the imported modules
   filepaths relative to the project root *)
let parse_module_header project_root current_file_path file =
  let lexbuf = Lexing.from_string file in
  let next () = Lexer.token Lexer.Normal lexbuf in
  let res = ref [] in
  let rec loop = function
    | Parser.IMPORT ->
       (match next () with
        | Parser.ID alias ->
           (match next () with
            | Parser.TEXT path ->
               let path =
                 import_relative_to_project_root
                   project_root
                   current_file_path
                   path in
               (match path with
                | Some path -> res := (alias, path) :: !res
                | None -> ());
               loop (next ())
            | tkn -> loop tkn)
        | tkn -> loop tkn)
    | Parser.EOF -> List.rev !res
    | tkn -> loop (next ()) in
  loop (next ())

(* Given a source file and a cursor position in that file, figure out
   the prefix relevant to searching completions. For example, given:

   List.fi| (where | is the cursor) return `Some ("List", "fi")` *)
let find_completion_prefix logger file line column: (string * string) option =
  (* The LSP sends 0 based line numbers *)
  let line = line + 1 in
  let lexbuf = Lexing.from_string file in
  let next () = Lexer.token Lexer.Normal lexbuf in
  let pos_eq_cursor pos =
    pos.Source.line = line && pos.Source.column = column in
  let pos_past_cursor pos =
    pos.Source.line > line
    || (pos.Source.line = line && pos.Source.column >= column) in
  let rec loop = function
    | _ when (pos_past_cursor (Lexer.region lexbuf).Source.right) -> None
    | Parser.ID ident ->
       (match next () with
        | Parser.DOT ->
           (match next () with
            | Parser.EOF -> Some (ident, "")
            | Parser.ID prefix ->
               let next_token_end = (Lexer.region lexbuf).Source.right in
               if pos_eq_cursor next_token_end
               then Some (ident, prefix)
               else loop (Parser.ID prefix)
            | tkn ->
               let next_token_start = (Lexer.region lexbuf).Source.left in
               if pos_past_cursor next_token_start
               then Some (ident, "")
               else loop tkn)
        | tkn -> loop tkn)
    | Parser.EOF -> None
    | _ -> loop (next ()) in
  loop (next ())

(* TODO(Christoph): Don't recompute the index whenever completions are
   requested *)
let completions (* index *) logger project_root file_path file_contents line column =
  let index = make_index () in
  let imported = parse_module_header project_root file_path file_contents in
  let module_alias_completion_item alias =
    Lsp_t.{
        completion_item_label = alias;
        completion_item_kind = 9;
        completion_item_insertText = alias;
        completion_item_insertTextFormat = 1;
        completion_item_detail = None;
    } in
  match find_completion_prefix logger file_contents line column with
  | None ->
     (* If we don't have any prefix to work with, just suggest the
        imported module aliases *)
     imported
     |> List.map (fun (alias, _) -> module_alias_completion_item alias)
  | Some (alias, prefix) ->
     let module_path =
       imported
       |> List.find_opt (fun (mn, _) -> String.equal mn alias) in
     match module_path with
     | Some mp ->
        (match Index.find_opt (snd mp) index with
         | Some decls ->
            decls
            |> List.filter (fun d -> d |> lbl_of_ide_decl |> Lib.String.chop_prefix prefix |> Lib.Option.is_some)
            |> List.map item_of_ide_decl
         | None ->
            (* The matching import references a module we haven't loaded *)
            [])
     | None ->
        (* No module with the given prefix was found *)
        []

let completion_handler logger project_root file_path file_contents position =
  let line = position.Lsp_t.position_line in
  let column = position.Lsp_t.position_character in
  `CompletionResponse
    (completions logger project_root file_path file_contents line column)

let test_completion () =
  Printf.printf "%s\n" (string_of_index (make_index ()))
