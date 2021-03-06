type expr =
  | CharLit of char
  | StrLit of string
  | IntLit of int
  | FltLit of float
  | Id of string
  | Cons of expr * expr
  | Quote of expr
  | Expansion
  | Nil

(* Convert an AST to string for inspection *)
let rec string_of_ast : expr -> string = function
  | StrLit x -> "\"" ^ String.escaped x ^ "\""
  | IntLit x -> string_of_int x
  | FltLit x -> (string_of_float x)^"f"
  | CharLit x -> "'" ^ Char.escaped x ^ "'"
  | Id name -> name
  | Quote v -> "Quote [" ^ string_of_ast v ^ "]"
  | Cons (a, b) -> "Cons [" ^ string_of_ast a ^ ", " ^ string_of_ast b ^ "]"
  | Expansion -> "..."
  | Nil -> "Nil"

(* Transform a list represented by Cons and Nil into an OCaml list, so
   that we can make use of list related functions like `map` in
   OCaml. *)
let rec cons_to_list : expr -> expr list = function
  | Cons (a, b) -> a :: cons_to_list b
  | Nil -> []
  | _ -> raise (Failure "cons_to_list called on non-list")

let rec list_to_cons : expr list -> expr = function
  | hd :: tl -> Cons (hd, list_to_cons tl)
  | [] -> Nil

(* Concat two cons list: cons_concat '(1 2) '(3 4) => '(1 2 3 4) *)
let rec cons_concat (a : expr) (b : expr) : expr =
  match (a, b) with
  | _, Nil -> a
  | Cons (hd, tl), b -> Cons (hd, cons_concat tl b)
  | Nil, b -> b
  | _ -> raise (Failure "invalid arguments to cons_concat")
