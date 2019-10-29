let extract_cursor input =
  let cursor_pos = ref (0, 0) in
  String.split_on_char '\n' input
  |> List.mapi
       (fun line_num line ->
         match String.index_opt line '|' with
         | Some column_num ->
            cursor_pos := (line_num, column_num);
            line
            |> String.split_on_char '|'
            |> String.concat ""
         | None -> line
       )
  |> String.concat "\n"
  |> fun f -> (f, !cursor_pos)

let dummy_logger _ _ = ()

let prefix_test_case file expected =
  let (file, (line, column)) = extract_cursor file in
  let show = function
    | None -> "None"
    | Some (m, p) -> "Some (" ^ m ^ ", " ^ p ^ ")" in
  let actual =
    Completion.find_completion_prefix dummy_logger file line column in
  Lib.Option.equal (=) actual expected ||
    (Printf.printf
       "\nExpected: %s\nActual:   %s\n"
       (show expected)
       (show actual);
     false)

let import_relative_test_case root module_path import expected =
  let actual =
    Completion.import_relative_to_project_root root module_path import in
  let show = function
    | None -> "None"
    | Some s -> "Some " ^ s in
  Lib.Option.equal String.equal actual expected ||
    (Printf.printf
       "\nExpected: %s\nActual:   %s\n"
       (show expected)
       (show actual);
     false)

let parse_module_header_test_case project_root current_file file expected =
  let actual =
    Completion.parse_module_header
      project_root
      current_file file in
  let display_result (alias, path) = Printf.sprintf "%s => \"%s\"" alias path in
  let result = Lib.List.equal
    (fun (x, y) (x', y') ->
      String.equal x x' && String.equal y y')
    actual
    expected in
  if not result then
    Printf.printf
      "\nExpected: %s\nActual:   %s"
      (Completion.string_of_list display_result expected)
      (Completion.string_of_list display_result actual) else ();
  result


let%test "it finds a simple prefix" =
  prefix_test_case "List.|" (Some ("List", ""))

let%test "it doesn't find non-qualified idents" =
  prefix_test_case "List.filter we|" None

let%test "it picks the qualified closest to the cursor" =
  prefix_test_case "Stack.some List.|" (Some ("List", ""))

let%test "it handles immediately following single character tokens" =
  prefix_test_case "List.|<" (Some ("List", ""))

let%test "it handles qualifier + partial identifier" =
  prefix_test_case "Stack.so|" (Some ("Stack", "so"))

let%test "it handles multiline files" =
  prefix_test_case
{|Stak.
List.|
|} (Some ("List", ""))

let%test "it handles a full module" =
  prefix_test_case
{|module {
  private import List = "./ListLib.mo";

  func singleton<T>(x: T): List.List<T> =
    List.cons<T>(x, Test.|<T>());

  func doubleton<T>(x: T): List.List<T> =
    List.cons<T>(x, List.cons<T>(x, List.nil<T>()));
 }|} (Some ("Test", ""))

let%test "it doesn't fall through to the next valid prefix" =
  prefix_test_case
{|module {
private import List = "lib/ListLib.mo"; // private, so we don't re-export List
private import ListFns = "lib/ListFuncs.mo"; // private, so we don't re-export List
type Stack = List.List<Int>;
func push(x : Int, s : Stack) : Stack = List.cons<Int>(x, s);
func empty():Stack = List.nil<Int>();
func singleton(x : Int) : Stack =
  List.we|
  ListFns.singleton<Int>(x);
}|} (Some ("List", "we"))

let%test "it makes an import relative to the project root" =
  import_relative_test_case
    "/home/project"
    "/home/project/src/main.mo"
    "lib/List.mo"
    (Some "src/lib/List.mo")

let%test "it preserves trailing slashes for directory imports" =
  import_relative_test_case
    "/home/project"
    "/home/project/src/main.mo"
    "lib/List/"
    (Some "src/lib/List/")

let%test "it can handle parent directory relationships" =
  import_relative_test_case
    "/home/project"
    "/home/project/src/main.mo"
    "../lib/List.mo"
    (Some "lib/List.mo")

let%test "it parses a simple module header" =
  parse_module_header_test_case
    "/project"
    "/project/src/Main.mo"
    "import P \"lib/prelude.mo\""
    ["P", "src/lib/prelude.mo"]

let%test "it parses a simple module header" =
  parse_module_header_test_case
    "/project"
    "/project/Main.mo"
    {|
module {

private import List "lib/ListLib.mo";
private import ListFuncs "lib/ListFuncs.mo";

type Stack = List.List<Int>;

func push(x: Int, s: Stack): Stack =
  List.cons<Int>(x, s);

func empty(): Stack =
  List.nil<Int>();

func singleton(x: Int): Stack =
  ListFuncs.doubleton<Int>(x, x);
}
|}
    [ ("List", "lib/ListLib.mo")
    ; ("ListFuncs", "lib/ListFuncs.mo")
    ]
