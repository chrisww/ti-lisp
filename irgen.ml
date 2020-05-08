module L = Llvm
module A = Ast
open Sast

(* References:

   - https://llvm.moe/ocaml/Llvm.html
   - https://mapping-high-level-constructs-to-llvm-ir.readthedocs.io/en/latest/basic-constructs/unions.html
 *)

type symbol_table = L.llvalue Symtable.symbol_table

let translate (stmts : stmt list) =
  let context = L.global_context () in
  let the_module = L.create_module context "ti-lisp" in

  let i1_t = L.i1_type context in
  let i8_t = L.i8_type context in
  let i32_t = L.i32_type context in
  let i64_t = L.i64_type context in

  let i8_ptr_t = L.pointer_type i8_t in

  let void_t = L.void_type context in

  let create_struct name ctx body =
    let struct_ = L.named_struct_type ctx name in
    L.struct_set_body struct_ body false;
    struct_
  in

  (* The union is represented by a 24-byte char array (Assuming each
     pointer is 8 bytes here). *)
  let value_type =
    create_struct "value_t" context [| i64_t; L.array_type i8_t 24 |]
  in
  let value_ptr_type = L.pointer_type value_type in
  let value_size = 32 in

  let type_integer = L.const_int i64_t 0
  and type_char = L.const_int i64_t 1
  and _type_string = L.const_int i64_t 2
  and _type_cons = L.const_int i64_t 3
  and type_bool = L.const_int i64_t 4
  and type_func = L.const_int i64_t 5 in

  (* When using a value as specific type, the value_type will be
     bitcasted to one of theses types *)
  let value_type_int = create_struct "value_t_int" context [| i64_t; i64_t |] in
  let value_type_char =
    create_struct "value_t_char" context [| i64_t; i8_t |]
  in
  let value_type_bool =
    create_struct "value_t_bool" context [| i64_t; i1_t |]
  in
  let _value_type_string =
    create_struct "value_t_string" context [| i64_t; i8_ptr_t; i64_t |]
  in
  let _value_type_cons =
    create_struct "value_t_cons" context
      [| i64_t; value_ptr_type; value_ptr_type |]
  in
  let value_type_func =
    create_struct "value_t_func" context
      [| i64_t; i8_ptr_t; i8_ptr_t; i8_t; i8_t |]
  in

  let display_func : L.llvalue =
    let display_t = L.function_type value_ptr_type [| value_ptr_type |] in
    L.declare_function "display" display_t the_module
  in

  let check_type_func : L.llvalue =
    let func_type = L.function_type void_t [| value_ptr_type; i8_t |] in
    L.declare_function "check_type" func_type the_module
  in

  let check_func_func : L.llvalue =
    let func_type = L.function_type void_t [| value_ptr_type; i8_t |] in
    L.declare_function "check_func" func_type the_module
  in

  let build_literal name type_value ltype values builder =
    let alloca = L.build_alloca value_type name builder in
    let type_field = L.build_struct_gep alloca 0 "value_type" builder in
    ignore (L.build_store type_value type_field builder);
    let casted =
      L.build_bitcast alloca (L.pointer_type ltype) "content" builder
    in
    List.iter
      (function
        | idx, value ->
            let field = L.build_struct_gep casted idx "field" builder in
            ignore (L.build_store value field builder))
      values;
    alloca
  in

  let build_memcpy src dest builder =
    let memcpy_func =
      let func_type =
        L.function_type void_t [| i8_ptr_t; i8_ptr_t; i64_t; i1_t |]
      in
      L.declare_function "llvm.memcpy.p0i8.p0i8.i64" func_type the_module
    in

    let dest = L.build_bitcast dest i8_ptr_t "memcpy_dest" builder in
    let src = L.build_bitcast src i8_ptr_t "memcpy_src" builder in
    L.build_call memcpy_func
      [| dest; src; L.const_int i64_t value_size; L.const_int i1_t 0 |]
      "" builder
  in

  let add_terminal builder instr =
    match L.block_terminator (L.insertion_block builder) with
    | Some _ -> ()
    | None -> ignore (instr builder)
  in

  let builtins = Symtable.from [ ("display", display_func) ] in

  (* Find which variables in outer function are used *)
  let rec collect_dependency (stmts : stmt list) (args : string list) :
      string list =
    let rec collect_dep_stmts (st : unit Symtable.symbol_table)
        (outer_vars : string list) (stmts : stmt list) :
        unit Symtable.symbol_table * string list =
      List.fold_left
        (fun ctx stmt ->
          let st, outer_vars = ctx in
          collect_dep_stmt st outer_vars stmt)
        (st, outer_vars) stmts
    and collect_dep_stmt (st : unit Symtable.symbol_table)
        (outer_vars : string list) :
        stmt -> unit Symtable.symbol_table * string list = function
      | Define (name, value) ->
          let st = Symtable.add name () st in
          (st, collect_dep_expr st outer_vars value)
      | Set (name, value) ->
          if Symtable.mem name st then (st, collect_dep_expr st outer_vars value)
          else (st, collect_dep_expr st (name :: outer_vars) value)
      | Expr expr -> (st, collect_dep_expr st outer_vars expr)
    and collect_dep_expr (st : unit Symtable.symbol_table)
        (outer_vars : string list) : expr -> string list = function
      | Id name ->
          if Symtable.mem name st || Symtable.mem name builtins then outer_vars
          else name :: outer_vars
      | If (pred, then_c, else_c) -> (
          let outer_vars = collect_dep_expr st outer_vars pred in
          let outer_vars = collect_dep_expr st outer_vars then_c in
          match else_c with
          | Some else_c -> collect_dep_expr st outer_vars else_c
          | None -> outer_vars )
      | Lambda (args, body) ->
          let st =
            List.fold_left (fun st name -> Symtable.add name () st) st args
          in
          let _, outer_vars = collect_dep_stmts st outer_vars body in
          outer_vars
      | Begin body ->
          let _, outer_vars = collect_dep_stmts st outer_vars body in
          outer_vars
      | Let (bindings, body) ->
          let st =
            List.fold_left
              (fun st binding ->
                let name, _ = binding in
                Symtable.add name () st)
              st bindings
          in
          let outer_vars =
            List.fold_left
              (fun outer_vars binding ->
                let _, expr = binding in
                collect_dep_expr st outer_vars expr)
              outer_vars bindings
          in
          let _, outer_vars = collect_dep_stmts st outer_vars body in
          outer_vars
      | FunCall (func, args) ->
          let outer_vars = collect_dep_expr st outer_vars func in
          List.fold_left (collect_dep_expr st) outer_vars args
      | _ -> outer_vars
    in

    let st = Symtable.from [] in
    let st = List.fold_left (fun st name -> Symtable.add name () st) st args in

    let _, outer_vars = collect_dep_stmts st [] stmts in
    List.sort_uniq String.compare outer_vars
  in

  let function_type (arg_size : int) : L.lltype =
    let args_types = Array.make (1 + arg_size) value_ptr_type in
    let access_link_type = i8_ptr_t in
    args_types.(0) <- access_link_type;
    L.function_type value_ptr_type args_types
  in

  (* Used to wrap builtin functions in a value_t, so that we can pass
     them as higher order functions *)
  let maybe_wrap_builtin (v : L.llvalue) (builder : L.llbuilder) : L.llvalue =
    match L.classify_type (L.element_type (L.type_of v)) with
    | L.TypeKind.Function ->
        let params = L.params v in
        if Array.length params = 0 then v
        else
          let first_param = params.(0) in
          let fp_type = L.type_of first_param in
          if
            L.classify_type fp_type = L.TypeKind.Pointer
            && L.classify_type (L.element_type fp_type) = L.TypeKind.Integer
          then
            (* Start wrapping *)
            (* TODO: support vaarg builtin here *)
            (* TODO: calculate args *)
            let func_ptr = L.build_bitcast v i8_ptr_t "func_ptr" builder in
            build_literal "builtin_wrapper" type_func value_type_func
              [
                (1, func_ptr);
                (2, L.const_null i8_ptr_t);
                (3, L.const_int i8_t 1);
                (4, L.const_int i8_t 1);
              ]
              builder
          else v
    | _ -> v
  in

  let rec build_stmt_block (func : L.llvalue) (st : symbol_table)
      (builder : L.llbuilder) (stmts : stmt list) :
      symbol_table * L.llbuilder * L.llvalue =
    List.fold_left
      (fun ctx stmt ->
        let st, builder, value = ctx in
        build_stmt func st builder stmt)
      (st, builder, L.const_null value_ptr_type)
      stmts
  and build_stmt (func : L.llvalue) (st : symbol_table) (builder : L.llbuilder)
      : stmt -> symbol_table * L.llbuilder * L.llvalue = function
    | Define (name, value) ->
        let alloca = L.build_alloca value_type name builder in
        let st = Symtable.add name alloca st in
        let builder, value = build_unnamed_expr func st builder value in
        ignore (build_memcpy value alloca builder);
        (st, builder, value)
    | Set (name, value) ->
        let builder, value = build_unnamed_expr func st builder value in
        ignore
          ( match Symtable.find name st with
          | Some pos -> build_memcpy value pos builder
          | _ -> raise (Failure "Undefined variable") );
        (st, builder, value)
    | Expr expr ->
        let builder, value = build_unnamed_expr func st builder expr in
        (st, builder, value)
  and build_unnamed_expr func st builder = build_expr func "unnamed" st builder
  and build_expr (the_func : L.llvalue) (name : string) (st : symbol_table)
      (builder : L.llbuilder) : expr -> L.llbuilder * L.llvalue = function
    | IntLit v ->
        ( builder,
          build_literal name type_integer value_type_int
            [ (1, L.const_int i64_t v) ]
            builder )
    | BoolLit v ->
        ( builder,
          build_literal name type_bool value_type_bool
            [ (1, L.const_int i1_t (if v then 1 else 0)) ]
            builder )
    | CharLit v ->
        ( builder,
          build_literal name type_char value_type_char
            [ (1, L.const_int i8_t (Char.code v)) ]
            builder )
    | Id name -> (
        match Symtable.find name st with
        | Some value -> (builder, maybe_wrap_builtin value builder)
        | None -> raise (Failure "Undefined variable") )
    | Begin body ->
        let _, builder, value = build_stmt_block the_func st builder body in
        (builder, value)
    | Let (bindings, body) ->
        (* This "let" is in fact "letrec" in standard scheme *)
        let st =
          List.fold_left
            (fun st binding ->
              let name, _ = binding in
              Symtable.add name (L.build_alloca value_type name builder) st)
            st bindings
        in
        let builder =
          List.fold_left
            (fun builder binding ->
              let name, expr = binding in
              let builder, value =
                build_unnamed_expr the_func st builder expr
              in
              ignore
                (build_memcpy value
                   ( match Symtable.find name st with
                   | Some pos -> pos
                   | None ->
                       raise
                         (Failure
                            "Programming Error: Let variables not in symbol \
                             table") )
                   builder);
              builder)
            builder bindings
        in
        let _, builder, value = build_stmt_block the_func st builder body in
        (builder, value)
    | If (pred, then_c, else_c) ->
        let builder, pred_val = build_expr the_func "cmp" st builder pred in
        let casted =
          L.build_bitcast pred_val
            (L.pointer_type value_type_bool)
            "bool_type_val" builder
        in
        let value_ptr = L.build_struct_gep casted 1 "bool_val_ptr" builder in
        let value = L.build_load value_ptr "bool_val" builder in
        let orig_builder = builder in
        ignore
          (L.build_call check_type_func [| pred_val; type_bool |] "" builder);
        let then_bb = L.append_block context "then" the_func in
        let builder, then_value =
          build_expr the_func "then" st
            (L.builder_at_end context then_bb)
            then_c
        in
        let else_bb = L.append_block context "else" the_func in
        let else_value =
          match else_c with
          | Some expr ->
              let _, value =
                build_expr the_func "else" st
                  (L.builder_at_end context else_bb)
                  expr
              in
              value
          | None -> L.const_null value_ptr_type
        in

        let end_bb = L.append_block context "end" the_func in
        let build_br_end = L.build_br end_bb in
        add_terminal (L.builder_at_end context then_bb) build_br_end;
        add_terminal (L.builder_at_end context else_bb) build_br_end;
        ignore (L.build_cond_br value then_bb else_bb orig_builder);
        let builder = L.builder_at_end context end_bb in
        let phi =
          L.build_phi
            [ (then_value, then_bb); (else_value, else_bb) ]
            "ifval" builder
        in
        (builder, phi)
    | FunCall (func, args) -> (
        let builder, func =
          match func with
          | Id name -> (
              match Symtable.find name st with
              | Some func -> (builder, func)
              | None -> raise (Failure ("Function " ^ name ^ " is not defined"))
              )
          | expr -> build_unnamed_expr the_func st builder expr
        in

        (* Reference: https://groups.google.com/forum/#!topic/llvm-dev/_xy_3ZpQFLI *)
        match L.classify_type (L.element_type (L.type_of func)) with
        (* User defined functions *)
        | L.TypeKind.Struct ->
            let arg_size = List.length args in
            (* check if value is really a function *)
            ignore
              (L.build_call check_func_func
                 [| func; L.const_int i8_t arg_size |]
                 "" builder);
            (* prepare arguments *)
            let builder, args =
              Utils.fold_map (build_unnamed_expr func st) builder args
            in
            (* bitcast the value to a function for calling *)
            let function_type = function_type arg_size in
            let casted =
              L.build_bitcast func
                (L.pointer_type value_type_func)
                "func_value" builder
            in
            (* access link *)
            let access_link =
              let access_link_ptr =
                L.build_struct_gep casted 2 "access_link_ptr" builder
              in
              let access_link =
                L.build_load access_link_ptr "access_link" builder
              in
              access_link
            in
            let args = Array.of_list (access_link :: args) in
            (* call the function pointer *)
            let func_ptr_ptr =
              L.build_struct_gep casted 1 "func_ptr_ptr" builder
            in
            let func_ptr = L.build_load func_ptr_ptr "func_ptr" builder in
            let func =
              L.build_inttoptr
                (L.build_ptrtoint func_ptr i64_t "func_ptr_val" builder)
                (L.pointer_type function_type)
                "func" builder
            in
            let ret = L.build_call func args "ret" builder in
            (builder, ret)
        (* Builtin functions *)
        | L.TypeKind.Function ->
            let builder, args =
              Utils.fold_map (build_unnamed_expr the_func st) builder args
            in
            let args = Array.of_list args in
            let ret = L.build_call func args "ret" builder in
            (builder, ret)
        | _ -> raise (Failure "Unexpected function type") )
    | Lambda (args, body) ->
        let arg_size = List.length args in
        let deps = collect_dependency body args in
        let func_type = function_type arg_size in
        let func = L.define_function "lambda" func_type the_module in
        let func_ptr = L.build_bitcast func i8_ptr_t "func_ptr" builder in
        (* The symbol table of the new function is built from "builtin"
           instead of inherited from the parent *)
        let new_st = Symtable.push builtins in
        (* set up access link *)
        let access_link_type =
          L.struct_type context (Array.make (List.length deps) value_ptr_type)
        in
        let access_link =
          L.build_alloca access_link_type "access_link" builder
        in

        List.iteri
          (fun index dep ->
            let field =
              L.build_struct_gep access_link index "access_link_field" builder
            in
            ignore
              (L.build_store
                 ( match Symtable.find dep st with
                 | Some value -> value
                 | None -> raise (Failure "Can't find variable for access link")
                 )
                 field builder))
          deps;
        (* Add arguments to the symbol table *)
        let new_st =
          List.fold_left2
            (fun st arg arg_name ->
              match arg_name with
              | "" -> st (* ignore the first argument *)
              | _ -> Symtable.add arg_name arg st)
            new_st
            (Array.to_list (L.params func))
            (* The first argument of a function is the
               access link, and it will not be added to
               the symbol table *)
            ("" :: args)
        in
        (* Build the function body *)
        build_func_body deps func new_st body;
        (* Wrap the function in a value_type instance *)
        let access_link_void_ptr =
          L.build_bitcast access_link i8_ptr_t "access_link_void_ptr" builder
        in
        let func_value =
          build_literal "lambda" type_func value_type_func
            [
              (1, func_ptr);
              (2, access_link_void_ptr);
              (3, L.const_int i8_t arg_size);
              (4, L.const_int i8_t arg_size);
            ]
            builder
        in
        (builder, func_value)
    | Nil -> (builder, L.const_null value_ptr_type)
    | _ ->
        raise
          (Failure "Not implemented. This expr cannot be converted to IR code")
  and build_func_body (deps : string list) (func : L.llvalue)
      (st : symbol_table) (stmts : stmt list) : unit =
    let builder = L.builder_at_end context (L.entry_block func) in
    (* The first argument is always access link *)
    let access_link_void_ptr = (L.params func).(0) in
    let access_link_type =
      L.struct_type context (Array.make (List.length deps) value_ptr_type)
    in
    let access_link =
      L.build_bitcast access_link_void_ptr
        (L.pointer_type access_link_type)
        "access_link" builder
    in
    let st =
      (* Reimport referenced variables into the symbol table from the
         access link *)
      List.fold_left
        (fun st var ->
          let index, name = var in
          let field_ptr =
            L.build_struct_gep access_link index "outer_var_ptr" builder
          in
          let field = L.build_load field_ptr "outer_var" builder in
          Symtable.add name field st)
        st
        (List.mapi (fun i name -> (i, name)) deps)
    in
    let _, builder, value = build_stmt_block func st builder stmts in
    ignore (L.build_ret value builder)
  and build_main_func_body (func : L.llvalue) (st : symbol_table)
      (stmts : stmt list) =
    let builder = L.builder_at_end context (L.entry_block func) in
    let _, builder, _ = build_stmt_block func st builder stmts in
    ignore (L.build_ret (L.const_int i32_t 0) builder)
  in

  let main_func =
    let main_func_type = L.function_type i32_t [||] in
    L.define_function "main" main_func_type the_module
  in
  build_main_func_body main_func builtins stmts;
  the_module
