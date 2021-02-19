(** This module is all you need to import for lexing Motoko source files.

  We lex in two phases:

  1. source_lexer.mll emits source_tokens, which also includes tokens for
     trivia (whitespace + comments)
  2. lexer.ml is a stream processor over the emitted source tokens. It:
     - Converts them into parser tokens
     - Disambiguates various tokens based on whitespace
     - Collects trivia per parser token and makes it available via a side channel
*)

module ST = Source_token

include module type of Lexer_lib

type pos = { line : int; column : int }

type trivia_info = {
  leading_trivia : ST.line_feed ST.trivia list;
  trailing_trivia : ST.void ST.trivia list;
}

val doc_comment_of_trivia_info : trivia_info -> string option

module PosHashtbl : Hashtbl.S with type key = pos

type triv_table = trivia_info PosHashtbl.t
val empty_triv_table : triv_table

type parser_token = Parser.token * Lexing.position * Lexing.position

(**
  Given a mode and a lexbuf returns a tuple of a lexing function
  and an accessor function for the collected trivia indexed by
  the start position for every token.
*)
val tokenizer : mode -> Lexing.lexbuf ->
    (unit -> parser_token) * (unit -> triv_table)
