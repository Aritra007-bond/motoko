open Extract

type output_format = Plain | Adoc | Html
type config = { source : string; output : string; name : string option }

let mkdir_recursive path =
  let segments = String.split_on_char '/' path in
  let _ =
    List.fold_left
      (fun acc dir ->
        let next = Filename.concat acc dir in
        (try Unix.mkdir next 0o777 with _ -> ());
        next)
      "." segments
  in
  ()

let write_file : string -> string -> unit =
 fun file output ->
  let dirname = Filename.dirname file in
  (try mkdir_recursive dirname with _ -> ());
  let oc = open_out file in
  Printf.fprintf oc "%s" output;
  flush oc;
  close_out oc

let extract : string -> extracted option =
 fun in_file ->
  let parse_result = Pipeline.parse_file Source.no_region in_file in
  match parse_result with
  | Error err ->
      Printf.eprintf "Skipping %s:\n" in_file;
      Diag.print_messages err;
      None
  | Ok ((prog, _), _) -> (
      match extract_docs prog with
      | Error err ->
          Printf.eprintf "Skipping %s:\n%s\n" in_file err;
          None
      | Ok x -> Some x)

let list_files_recursively : string -> string list =
 fun dir ->
  let rec loop result = function
    | f :: fs when Sys.is_directory f ->
        Sys.readdir f
        |> Array.to_list
        |> List.map (Filename.concat f)
        |> List.append fs
        |> loop result
    | f :: fs -> loop (f :: result) fs
    | [] -> result
  in
  loop [] [ dir ]

let list_files : string -> string -> (string * string * string) list =
 fun source output ->
  (* Printf.printf "%s -> %s\n" source output; *)
  let all_files = list_files_recursively source in
  let all_files =
    List.filter (fun f -> Filename.extension f = ".mo") all_files
  in
  List.map
    (fun file ->
      file
      |> Lib.FilePath.relative_to source
      |> Option.get
      |> Lib.String.chop_suffix ".mo"
      |> Option.get
      |> fun f -> (file, Filename.concat output f, f))
    all_files

let make_render_inputs : config -> (string * Common.render_input) list =
 fun { source; output; name; _ } ->
  let all_files = List.sort compare (list_files source output) in
  let all_modules = List.map (fun (_, _, rel) -> rel) all_files in
  List.filter_map
    (fun (input, output, current_path) ->
      Option.map
        (fun { module_comment; docs; lookup_type } ->
          ( output,
            Common.
              {
                all_modules;
                current_path;
                lookup_type;
                module_comment;
                declarations = docs;
                package_name = name;
              } ))
        (extract input))
    all_files

let start : output_format -> config -> unit =
 fun format config ->
  let { source; output; name } = config in
  (try Unix.mkdir output 0o777 with _ -> ());
  match format with
  | Plain ->
      let inputs = make_render_inputs config in
      List.iter
        (fun (out, input) -> write_file (out ^ ".md") (Plain.render_docs input))
        inputs;
      write_file
        (Filename.concat output "index.md")
        (Plain.make_index (List.map snd inputs))
  | Adoc ->
      let inputs = make_render_inputs config in
      List.iter
        (fun (out, input) ->
          write_file (out ^ ".adoc") (Adoc.render_docs input))
        inputs
  | Html ->
      write_file (Filename.concat output "styles.css") Styles.styles;
      let inputs = make_render_inputs config in
      List.iter
        (fun (out, input) ->
          write_file (out ^ ".html") (Html.render_docs input))
        inputs;
      write_file
        (Filename.concat output "index.html")
        (Html.make_index (List.map snd inputs))
