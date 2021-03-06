(****************************************************************************)
(* Copyright (c) 2010-13,                                                   *)
(*                        Foivos    Zakkak          <zakkak@ics.forth.gr>   *)
(*                        Polyvios  Pratikakis      <polyvios@ics.forth.gr> *)
(*                                                                          *)
(*                        FORTH-ICS / CARV                                  *)
(*                        (Foundation for Research & Technology -- Hellas,  *)
(*                         Institute of Computer Science,                   *)
(*                         Computer Architecture & VLSI Systems Laboratory) *)
(*                                                                          *)
(*                                                                          *)
(*                                                                          *)
(* Licensed under the Apache License, Version 2.0 (the "License");          *)
(* you may not use this file except in compliance with the License.         *)
(* You may obtain a copy of the License at                                  *)
(*                                                                          *)
(*     http://www.apache.org/licenses/LICENSE-2.0                           *)
(*                                                                          *)
(* Unless required by applicable law or agreed to in writing, software      *)
(* distributed under the License is distributed on an "AS IS" BASIS,        *)
(* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. *)
(* See the License for the specific language governing permissions and      *)
(* limitations under the License.                                           *)
(****************************************************************************)

(** Includes all the generic functions (utilities) *)

open Cil
module E  = Errormsg
module H  = Hashtbl
module L  = List
module CG = Callgraph
module S  = Stack

(******************************************************************************)
(*                          Types                                             *)
(******************************************************************************)
(*
(** the argument type supported by the annotations *)
type arg_t =
    In
  | Out
  | InOut
  | TIn
  | TOut
  | TInOut
  | SIn
  | SOut
  | SInOut

(** the argument description, extracted by the annotations *)
and arg_descr = (string * (exp * arg_t * exp * exp * exp))*)

(** The argument description, extracted by the annotations *)
type arg_descr =
  {
    mutable aname: string;    (** The arguments' name *)
    mutable address: exp;     (** The arguments' address *)
    mutable atype: arg_type;  (** The argument's type *)
  }

(** The arguments' type *)
and arg_type =
  | Scalar of arg_flow * exp (** Scalar arguments only need their size (maybe not) *)
  | Stride of arg_flow * exp * exp * exp (** Stride args have three sizes
                                  1. stride size
                                  2. number of elements
                                  3. size of a single element
                              *)
  | Normal of arg_flow * exp (** Normal arguments only need their size *)
  | Region of arg_flow * string list (** Region arguments include all the
                                      arguments of the region *)
  | NTRegion of arg_flow * string list (** No transfer arguments include all the
                                      arguments of the region that should not be
                                      transfered *)

(** The arguments' data flow *)
and arg_flow =
  | IN
  | OUT
  | INOUT

(******************************************************************************)
(*                          Globals                                           *)
(******************************************************************************)

(** define the ppu_vector *)
let ppu_vector = Attr("altivec", [ACons("vector__", [])])

(** keeps the function we are in at the current point (scoping) *)
let current_function = ref dummyFunDec

(** keeps whether stats are enabled or not *)
let stats = ref true
(** keeps whether we want unaligned arguments or not *)
let unaligned_args = ref false


(******************************************************************************)
(*                                BOOLEAN                                     *)
(******************************************************************************)

(** Check if an exp uses an index
    @param e the expression to check
    @return true or false
 *)
let uses_index (e: exp) : bool =
  match (e) with
    (BinOp(PlusPI, _, _, _))
    | (BinOp(IndexPI, _, _, _))
    | (Lval(_, Index(_, _))) -> true
    | _ -> false

(** Check if an argument is stride
    @param arg the arguments' descriptor
    @return true or false
*)
let is_strided (arg: arg_descr) : bool =
   match arg.atype with
    | Stride(_) -> true
    | _ -> false

(** Check if an argument is scalar
    @param arg the argument's type
    @return true or false
*)
let is_scalar (arg: arg_descr) : bool =
   match arg.atype with
      Scalar(_) -> true
    | _ -> false

(** Check if an argument is region
    @param arg the argument's type
    @return true or false
*)
let is_region (arg: arg_descr) : bool =
   match arg.atype with
      Region(_) -> true
    | _ -> false

(** Check if an argument is a no transfer region
    @param arg the argument's type
    @return true or false
*)
let is_NT_region (arg: arg_descr) : bool =
   match arg.atype with
      NTRegion(_) -> true
    | _ -> false

(** Check if an arguments type is out
    @param arg the argument's type
    @return true or false
*)
let is_out (arg: arg_descr) : bool =
   match arg.atype with
      Scalar(OUT, _)
    | Stride(OUT, _, _, _)
    | Normal(OUT, _)
    | Region(OUT, _)
    | NTRegion(OUT, _) -> true
    | _ -> false

(** Check if an arguments type is in
    @param arg the argument's type
    @return true or false
*)
let is_in (arg: arg_descr) : bool =
   match arg.atype with
      Scalar(IN, _)
    | Stride(IN, _, _, _)
    | Normal(IN, _)
    | Region(IN, _)
    | NTRegion(IN, _) -> true
    | _ -> false

(** Check if there is any indiced argument in the task (if any task) in the given
    statement
    @param st the statement to check
    @return true or false
*)
let tpc_call_with_arrray (st: stmt) : bool =
  if (st.pragmas <> []) then begin
    match (L.hd st.pragmas) with
      (Attr("css", _), _) -> begin
        match (st.skind)  with
          Instr(Call(_, _, args, _)::_) -> L.exists uses_index args
          | _ -> false
      end
      | _ -> false
  end else
    false

(** Check if a [Cil.global] is {b not} the function declaration of "main"
    @param g the global to check
    @return true or false
*)
let is_not_main (g: global) : bool = match g with
    GFun({svar = vi}, _) when (vi.vname = "main") -> false
  | _ -> true

(** Check if a [Cil.global] is {b not} the function declaration of "tpc_call_tpcAD65"
    @param g the global to check
    @return true or false
*)
let is_not_skeleton (g: global) : bool = match g with
    GFun({svar = vi}, _) when (vi.vname = "tpc_call_tpcAD65") -> false
  | _ -> true

(** Check if a global is a typedef, enum, struct or union
    @param g the global to check
    @return true or false
*)
let is_typedef (g: global) : bool = match g with
    GType(_, _)
  | GCompTag(_, _)
  | GCompTagDecl(_, _)
  | GEnumTag(_, _)
  | GEnumTagDecl(_, _) -> true
  | GVarDecl(vi, _) when vi.vstorage=Extern -> true
  | _ -> false

(** Check whether a type is TComp
    @return true or false
*)
let isCompType = function
  | TComp _ -> true
  | _ -> false

(** Check whether a type is scalar
    @param t the type [Cil.typ]
    @return true or false
*)
let is_scalar_t =  function
  | TVoid _
  | TPtr _
  | TArray _
  | TFun _ -> false
  | _ -> true

(** Check whether a variable is scalar
    @param vi the variable's [Cil.varinfo]
    @return true or false
*)
let is_scalar_v (vi: varinfo) =  is_scalar_t vi.vtype


(******************************************************************************)
(*                          Search Functions                                  *)
(******************************************************************************)

(** Exception returning the found function declaration *)
exception Found_fundec of fundec
(** searches a global list for a function definition with name {e name}
    @param g the global list to search in
    @param name the name of the function to search
    @raise Not_found when there is no function declaration with name
      {e name} in {e g}
    @return the Cil.fundec of the function named {e name} *)
let find_function_fundec_g (g: global list) (name: string) : fundec =
  let findit = function
    | GFun(fd, _) when fd.svar.vname = name -> raise (Found_fundec fd)
(*     | GFun(fd, _) -> print_endline fd.svar.vname; () *)
    | _ -> ()
  in
  try
    List.iter findit g;
    raise Not_found
  with Found_fundec v -> v

(** find the function definition of variable {e name} in file {e f}
    @param f the file to look in
    @param name the name of the function to search
    @raise Not_found when there is no function declaration with name
      {e name} in {e f}
    @return the Cil.fundec of the function named {e name}
 *)
let find_function_fundec (f: file) (name: string) : fundec =
  try find_function_fundec_g f.globals name
  with Not_found -> (
    ignore(error "Function declaration of \"%s\" not found\n" name);
    raise Not_found
  )

(** Exception returning the found function signature *)
exception Found_sign of varinfo
(** this is the private function *)
let __find_function_sign (f: file) (name: string) : varinfo =
  let findit = function
    | GVarDecl(vi, _) when vi.vname = name -> raise (Found_sign vi)
    | GFun(fd, _) when fd.svar.vname = name -> raise (Found_sign fd.svar)
    | _ -> ()
  in
  try
    iterGlobals f findit;
    raise Not_found
  with Found_sign v -> v
(** find the function signature for {e name} function in file {e f}
    @param f the file to look in
    @param name the name of the function to search
    @raise Not_found when there is no function signature with name
      {e name} in {e f}
    @return the Cil.varinfo of the function named {e name}
 *)
let find_function_sign (f: file) (name: string) : varinfo =
  try __find_function_sign f name
  with Not_found -> (
    ignore(error "Function signature of \"%s\" not found\n" name);
    raise Not_found
  )

(** Exception returning the found type *)
exception Found_type of typ
(** find the {b first} typedef for type {e name} in file {e f}
    @param f the file to look in
    @param name the name of the type to search
    @raise Not_found when there is no type with name {e name} in {e f}
    @return the Cil.typ of the function named {e name}
 *)
let find_type (f: file) (name: string) : typ =
  let findit = function
    | GType(ti, _) when ti.tname = name -> raise (Found_type (TNamed(ti, [])))
    | _ -> ()
  in
  try
    iterGlobals f findit;
    ignore(error "Type \"%s\" not found\n" name);
    raise Not_found
  with Found_type t -> t

(** find the struct or union named struct/union {e name} in file {e f}
    @param f the file to look in
    @param name the name of the struct/union to search
    @raise Not_found when there is no struct or union with name {e name} in {e f}
    @return the Cil.typ of the function named {e name}
 *)
let find_tcomp (f: file) (name: string) : typ =
  let findit = function
    | GCompTag(ci, _) when ci.cname = name -> raise (Found_type (TComp(ci, [])))
    | _ -> ()
  in
  try
    iterGlobals f findit;
    ignore(error "Struct ot Union \"%s\" not found\n" name);
    raise Not_found
  with Found_type t -> t

(** Exception returning the found global *)
exception Found_Gvar of global

(** find the global variable named {e name} in the globals of {e f}
    (doesn't print anything on fail)
    @param f the file to look in
    @param name the name of the local variable to search
    @raise Not_found when there is no local variable with name {e name} in {e fd}
    @return the Cil.varinfo of the local variable {e name}
 *)
let find_global_Gvar (f: file) (name: string) : global =
  let findit gv = match gv with
    GVar(vi, _, _) when vi.vname = name -> raise (Found_Gvar gv)
    | _ -> ()
  in
  try
    iterGlobals f findit;
    ignore(error "Global variable \"%s\" not found\n" name);
    raise Not_found
  with Found_Gvar v -> v

(** Exception returning the found varinfo *)
exception Found_var of varinfo

(** find the global variable named {e name} in the globals of {e f}
    (doesn't print anything on fail)
    @param f the file to look in
    @param name the name of the local variable to search
    @raise Not_found when there is no local variable with name {e name} in {e fd}
    @return the Cil.varinfo of the local variable {e name}
 *)
let __find_global_var (f: file) (name: string) : varinfo =
  let findit = function
    | GVarDecl(vi, _) when vi.vname = name -> raise (Found_var vi)
    | GVar(vi, _, _) when vi.vname = name -> raise (Found_var vi)
    | _ -> ()
  in
  try
    iterGlobals f findit;
    raise Not_found
  with Found_var v -> v

(** find the global variable named {e name} in file {e f}
    @param f the file to look in
    @param name the name of the global variable to search
    @raise Not_found when there is no global variable with name {e name} in {e f}
    @return the Cil.varinfo of the global variable {e name}
 *)
let find_global_var (f: file) (name: string) : varinfo =
  try __find_global_var f name
  with Not_found -> (
    ignore(error "Global variable \"%s\" not found\n" name);
    raise Not_found
  )

(** this is the private function *)
let __find_formal_var (fd: fundec) (name: string) : varinfo =
  let findit = function
    | vi when vi.vname = name -> raise (Found_var vi)
    | _ -> ()
  in
  try
    List.iter findit fd.sformals;
    raise Not_found
  with Found_var v -> v
(** find the variable named {e name} in the formals of {e fd}
    @param fd the function declaration to look in
    @param name the name of the formal variable to search
    @raise Not_found when there is no formal variable with name {e name} in {e fd}
    @return the Cil.varinfo of the formal variable {e name}
 *)
let find_formal_var (fd: fundec) (name: string) : varinfo =
  try __find_formal_var fd name
  with Not_found -> (
    ignore(error "Formal variable \"%s\" not found in function \"%s\"\n" name fd.svar.vname);
    raise Not_found
  )

(** find the variable named {e name} in the locals of {e fd}
    (doesn't print anything on fail)
    @param fd the function declaration to look in
    @param name the name of the local variable to search
    @raise Not_found when there is no local variable with name {e name} in {e fd}
    @return the Cil.varinfo of the local variable {e name}
 *)
let __find_local_var (fd: fundec) (name: string) : varinfo =
  let findit = function
    | vi when vi.vname = name -> raise (Found_var vi)
(*     | vi -> print_endline vi.vname *)
    | _ -> ()
  in
  try
    List.iter findit fd.slocals;
    raise Not_found
  with Found_var v -> v
(** find the variable named {e name} in the locals of {e fd}
    @param fd the function declaration to look in
    @param name the name of the local variable to search
    @raise Not_found when there is no local variable with name {e name} in {e fd}
    @return the Cil.varinfo of the local variable {e name}
 *)
let find_local_var (fd: fundec) (name: string) : varinfo =
  try __find_local_var fd name
  with Not_found -> (
    ignore(error "Local variable \"%s\" not found in function \"%s\"\n" name fd.svar.vname);
    raise Not_found
  )

(** find the variable named {e name} in fundec {e fd}
   else look if it's a global of file {e f}
    @param fd the function declaration to look in
    @param f the file to look in
    @param name the name of the formal variable to search
    @raise Not_found when there is no variable with name {e name} in {e fd} of {e f}
    @return the Cil.varinfo of the variable {e name}
 *)
let find_scoped_var (loc: location) (fd: fundec) (f: file) (name: string) : varinfo =
  try
    __find_local_var fd name
  with Not_found ->
      ( try
        __find_formal_var fd name
      with Not_found ->
          ( try
            __find_global_var f name
          with Not_found ->
              E.s (errorLoc loc "\"%s\" was not found in the current scope" name)
          )
      )

(** Exception returning the found enum *)
exception Found_enum of enuminfo
(** find the enum named {e name} in file {e f}
    @param f the file to look in
    @param name the name of the enum to search
    @raise Not_found when there is no enum with name {e name} in {e fd} of {e f}
    @return the Cil.enuminfo of the enum {e name}
 *)
let find_enum (f: file) (name: string) : enuminfo =
  let findit = function
    | GEnumTag(ei, _) when ei.ename = name -> raise (Found_enum ei)
    | _ -> ()
  in
  try
    iterGlobals f findit;
    raise Not_found
  with Found_enum ei -> ei



(******************************************************************************)
(*                                Converters                                  *)
(******************************************************************************)


(** Takes an expression and changes it if it's a scalar to its address
    @param e the expression to get the address of
    @return the new expression (& old_expression)
 *)
let rec scalar_exp_to_pointer (loc: location) (e: exp) : exp =
  match e with
  | AddrOf _
  | StartOf _ -> e
  | Const _ -> E.s (unimp "%a\n\tConstants are not supported yet as a task arguments" d_loc loc)
  | SizeOf _
  | SizeOfE _
  | SizeOfStr _ -> E.s (unimp "%a\n\tsizeof is not supported yet as a task argument" d_loc loc)
  | AlignOf _
  | AlignOfE _ -> E.s (unimp "%a\n\tAlignOf is not supported yet as a task argument" d_loc loc)
  | UnOp _
  | BinOp _ -> E.s (unimp "%a\n\tOperations are not supported yet as task arguments" d_loc loc)
  | CastE (t, e') -> (
    match t with
    | TVoid _
    | TPtr _
    | TArray _
    | TFun _ -> e
    | _ -> CastE(TPtr(t, []), scalar_exp_to_pointer loc e')
  )
  | Lval (lh, off) -> (
    match lh with
      Var vi -> (
        if (is_scalar_v vi) then
          mkAddrOrStartOf (lh, off)
        else
          e
      )
      | Mem e' -> e'
  )
  | Question _ -> E.s (unimp "%a\n\tConditionals are not supported yet as task arguments" d_loc loc)

(** Takes a function declaration and changes the types of its scalar formals to pointers
    @param f the function declaration to change
 *)
let formals_to_pointers (loc: location) (f: fundec) : unit =
  match f.svar.vtype with
    TFun (rt, Some args, va, a) ->
      if (va) then
        E.s (errorLoc loc "Functions with va args cannot be executed as tasks");

      let scalarToPointer arg =
        let (name, t, a) = arg in
        if (is_scalar_t t) then
          (name, TPtr(t, []), a)
        else
          arg
      in
      let formals = f.sformals in
      let args = List.map scalarToPointer args in
      (* Change the function type. *)
      f.svar.vtype <- TFun (rt, Some args, false, a);

      let scalarToPointer arg =
        if (is_scalar_t arg.vtype) then
          arg.vtype <- TPtr(arg.vtype, [])
        else
          ()
      in
      List.iter scalarToPointer formals;
    | TFun (_) -> ();
    | _ -> assert false

(** Converts the {e arg} describing the argument type to arg_flow
    @param arg the string (in/out/inout/input/output) describing the type of the argument
    @return the corresponding arg_flow
 *)
let arg_flow_of_string (arg: string) (loc: location): arg_flow =
  match arg with
    | "in" (* legacy *)
    | "input" -> IN
    | "out" (* legacy *)
    | "output" -> OUT
    | "inout" -> INOUT
    | _ -> E.s (errorLoc loc "Only in/out/input/output/inout are allowed")

(** Maps the argument type to a number as defined by the TPC headers
    @return the corrensponding number *)
let int_of_arg_type (arg_t: arg_type) : int =
  let flow2int = function
      IN -> 1
    | OUT -> 2
    | INOUT -> 3
  in
  match arg_t with
      Scalar( flow, _)
    | Stride ( flow, _, _, _)
    | Normal ( flow, _)
    | Region ( flow, _)
    | NTRegion ( flow, _) -> (flow2int flow)


(** Returns a string discribing the argument as IN/OUT/INOUT
    @return the corrensponding string *)
let string_of_arg_type (arg_t: arg_type) : string =
  let flow2str = function
      IN -> "IN"
    | OUT -> "OUT"
    | INOUT -> "INOUT"
  in
  match arg_t with
      Scalar( flow, _)
    | Stride ( flow, _, _, _)
    | Normal ( flow, _)
    | Region ( flow, _)
    | NTRegion ( flow, _) -> (flow2str flow)

(** Checks if tag is data annotation.
    @param typ the dataflow annotation
    @return true if it is dataflow annotation
 *)
let is_dataflow_tag (typ: string): bool =
  match typ with
  | "safe" -> false
  | _      -> true

(** Maps the arg_t to ints as defined by the TPC headers
    @return the corrensponding int *)
let integer_exp_of_arg_type t = integer (int_of_arg_type t)


(******************************************************************************)
(*                         Copy Function                                      *)
(******************************************************************************)

(** recursively copies a function definition and all it's callees
   from the {e ppc_file} to the {e spu_file}
    @param func the name of the function to be copied
    @param callgraph the callgraph of the program
    @param spu_file the spu file
    @param ppc_file the ppc file
*)
let rec deep_copy_function (func: string) (callgraph: CG.callgraph)
      (spu_file: file) (ppc_file: file)= (
    (* TODO copy globals? *)

    (* First copy the Callees *)
    let cnode: CG.callnode = H.find callgraph func in
    let nodeName = function
      | CG.NIVar (v, _) -> v.vname
      | CG.NIIndirect (n, _) -> n
    in
    let deep_copy _ (n: CG.callnode) : unit =
      let name = nodeName n.CG.cnInfo in
      deep_copy_function name callgraph spu_file ppc_file
    in
    Inthash.iter deep_copy cnode.CG.cnCallees;

    (* now copy current *)
    try
      (* First check whether the function is defined *)
      let new_fd = GFun(find_function_fundec_g (ppc_file.globals) func, locUnknown) in
      try
        (* Now check if this function is already defined in the spu file *)
        ignore(find_function_fundec_g (spu_file.globals) func)
      with Not_found -> spu_file.globals <- spu_file.globals@[new_fd];
      (* if not check whether we have a signature *)
    with Not_found -> ignore(find_function_sign (ppc_file) func);
)

(******************************************************************************)
(*                               GETTERS                                      *)
(******************************************************************************)

(** changes the return type of a function
    @param f the function declaration of the function to change
    @param t the new type for the function to return
 *)
let set_function_return_type (f: fundec) (t: typ) : unit = begin
  match unrollType f.svar.vtype with
    TFun (_, Some args, va, a) ->
      f.svar.vtype <- TFun(t, Some args, va, a);
    | _ -> assert false
end

(*(** returns the extra formal arguments added to a tpc_function_* by SCOOP *)
let get_tpc_added_formals (new_f: fundec) (old_f: fundec) : varinfo list = begin
  List.filter
    (fun formal ->
        List.exists
          (fun formal2 -> formal <> formal2 )
          old_f.sformals
    )
    new_f.sformals
end*)

let getCompinfo = function
  (* unwrap the struct *)
    TComp (ci, _) -> ci
  (* if it's not a struct, die. too bad. *)
  | _ -> assert false

(** get the name of the variable if any
    @raise Invalid_argument if the given expression doesn't include a single variable
    @return the name of the variable included in the given Cil.exp *)
let rec get_name_of_exp = function
      Lval ((Var(vi),_))
    | AddrOf ((Var(vi),_))
    | StartOf ((Var(vi),_)) -> vi.vname
    | CastE (_, ex)
    | AlignOfE ex
    | SizeOfE ex -> get_name_of_exp ex
    (* The following are not supported yet *)
    | Const _ -> raise (Invalid_argument "Const");
    | SizeOf _ -> raise (Invalid_argument "Sizeof");
    | SizeOfStr _ -> raise (Invalid_argument "SizeofStr");
    | AlignOf _ -> raise (Invalid_argument "Alignof");
    | UnOp _ -> raise (Invalid_argument "UnOp");
    | BinOp _ -> raise (Invalid_argument "BinOp");
    | _ -> raise (Invalid_argument "Unknown")

(** gets the basetype of {e t}
    @param the type
    @param the variables name (for error printing)
    @return the basetype of {e t}
 *)
let get_basetype (t: typ) (name: string) : typ =
  match t with
    TVoid _ -> ignore(error "Found void expression as task argument \"%s\"\n" name); t
  | TInt _
  | TFloat _
  | TNamed _
  | TComp _
  | TEnum _
  | TArray (_, Some _, _)
  | TPtr (TVoid _, _)-> t
  | TPtr (t', _)-> t'
  | TArray _ -> ignore(warn "I can't guess the size of array \"%s\"\n" name); t
  | TFun _ -> ignore(error "Found function as task argument \n"); t
  | TBuiltin_va_list _ -> ignore(error "Found variable args as task argument \n"); t


(** returns the arg_flow of {e arg}
    @param arg the arguments' description
    @return the argument flow type
*)
let get_arg_flow (arg: arg_descr) : arg_flow =
   match arg.atype with
      Scalar(flow, _)
    | Stride(flow, _, _, _)
    | Normal(flow, _)
    | Region(flow, _)
    | NTRegion(flow, _) -> flow


(** returns the expression with the size of {e arg}
    @param arg the arguments' description
    @return the expression with the args' size
*)
let get_arg_size (arg: arg_descr) : exp =
   match arg.atype with
      Scalar(_, size)
    | Stride(_, size, _, _)
    | Normal(_, size) -> size
    | Region(_, _)
    | NTRegion(_, _) -> zero

(******************************************************************************)
(*                                   LOOP                                     *)
(******************************************************************************)

(** exception returning the stmt that failed to give a loop lower bound *)
exception CouldntGetLoopLower of stmt
(** returns the lower bound of a loop
    @param s the loop stmt
    @param prevstmt the previously visited statement
    @raise CouldntGetLoopLower when it fails
    @return the lower bound of the loop as a Cil.exp
  *)
let get_loop_lower (s: stmt) (prevstmt: stmt) : exp =
  match (prevstmt).skind with
      Instr(il) -> begin
        match (L.hd (L.rev il)) with
          Set(_, e, _) -> e
        | _ -> raise (CouldntGetLoopLower s)
      end
    | _ -> raise (CouldntGetLoopLower s)

(** exception returning the stmt that failed to give a loop upper bound *)
exception CouldntGetLoopUpper of stmt
(** returns the upper bound of a loop
    @param s the loop stmt
    @raise CouldntGetLoopUpper when it fails
    @return the upper bound of the loop as a Cil.exp
  *)
let get_loop_condition (s: stmt) : exp =
  match s.skind with
      Loop(b, _, _, _) -> begin
        match (L.hd b.bstmts).skind with
            If(ec, _, _, _) -> ec
(*           | If(UnOp(LNot, ec, _), _, _, _) -> ec *)
          | _ -> raise (CouldntGetLoopUpper s)
      end
    | _ -> raise (CouldntGetLoopUpper s)

(** exception returning the stmt that failed to give a loop successor expression *)
exception CouldntGetLoopSuccessor of stmt
(** returns the successor expression (step) of a loop
    @param s the loop stmt
    @raise CouldntGetLoopSuccessor when it fails
    @return the successor (step) of the loop as a Cil.exp
  *)
let get_loop_successor (s: stmt) : exp =
  match s.skind with
      Loop(b, _, _, _) -> begin
        let lstmt = L.hd (L.rev b.bstmts) in
          match lstmt.skind with
            Instr(il) -> begin
              match (L.hd (L.rev il)) with
                Set(_, e, _) -> e
              | _ -> raise (CouldntGetLoopSuccessor s)
            end
          | _ -> raise (CouldntGetLoopSuccessor s)
      end
    | _ -> raise (CouldntGetLoopSuccessor s)


(******************************************************************************)
(*                             FILE handling                                  *)
(******************************************************************************)

(** writes an AST (list of globals) into a file
    @param f the file to be written
    @param fname  the name of the file on the disk
    @param globals  the globals of the file to be written
*)
let write_new_file f fname globals = begin
  let file = { f with
    fileName = fname;
    globals  = globals;
  } in
  let oc = open_out fname in
  Rmtmps.removeUnusedTemps file;
  dumpFile defaultCilPrinter oc fname file;
  close_out oc
end

(** writes out file {e f}
    @param f the file to be written
*)
let write_file f = begin
  let oc = open_out f.fileName in
  Rmtmps.removeUnusedTemps f;
  dumpFile defaultCilPrinter oc f.fileName f;
  close_out oc
end

(******************************************************************************)
(*                                 MISC                                       *)
(******************************************************************************)

class changeStmtVisitor (s: stmt) (name: string) (stl: stmt list) : cilVisitor =
  object (self)
    inherit nopCilVisitor
    method vstmt (s: stmt) = match s.skind with
      (*Instr(Call(_, Lval((Var(vi), _)), _, _)::res) when vi.vname = name ->
        ChangeTo (mkStmt (Block (mkBlock (stl@[mkStmt (Instr(res))]))))*)
      Instr(instrs) ->
        let first    = ref [] in
        let second   = ref [] in
        let found    = ref false in
        let iter_fun = (
          fun i -> match i with
            Call(_, Lval((Var(vi), _)), _, _) when vi.vname = name -> found := true;
          | _ -> if (!found) then (second := i::!second) else (first := i::!first);
        ) in
        L.iter iter_fun instrs;
        if (!found = false) then
          DoChildren
        else
          ChangeTo (mkStmt (Block (mkBlock (mkStmt (Instr(L.rev !first))::stl@[mkStmt (Instr(L.rev !second))]))))
    | _ -> DoChildren
  end

(** replaces the call to the {e fake} function with a statement list
    @param s the targeted [Cil.stmt] for the replacement
    @param fake the name of the function call to replace
    @param stl the [Cil.stmt list] to replace the fake call
*)
let replace_fake_call_with_stmt (s: stmt) (fake: string) (stl: stmt list) =
  let v = new changeStmtVisitor s fake stl in
  visitCilStmt v s

(** Comparator for use with [List.sort]. Checks which pair has the bigger int *)
let comparator (a: (int * exp)) (b: (int * exp)) : int =
  let (a_i, _) = a in
  let (b_i, _) = b in
  if (a_i = b_i) then 0
  else if (a_i > b_i) then 1
  else (-1)


(** Comparator for use with [List.sort],
    takes an arg_descr list and sorts it according to the type of the arguments
    input @ inout @ output *)
let sort_args (a: arg_descr) (b: arg_descr) : int =
  (* if they are equal *)
  if ((get_arg_flow a) = (get_arg_flow b)) then 0
  (* if a is Out *)
  else if (is_out a) then 1
  (* if b is Out *)
  else if (is_out b) then (-1)
  (* if neither are Out and a is In *)
  else if (is_in a) then (-1)
  else 1

(** Comparator for use with [List.sort], takes an (int*arg_descr) list
    and sorts it according to the int of the elements (descending) *)
let sort_args_n ((an, a): (int*arg_descr)) ((bn,b): (int*arg_descr)) : int =
  if (an = bn) then 0
  else if (an < bn) then 1
  else -1

(** Comparator for use with [List.sort], takes an (int*arg_descr) list
    and sorts it according to the int of the elements (ascending) *)
let sort_args_n_inv ((an, a): (int*arg_descr)) ((bn,b): (int*arg_descr)) : int =
  sort_args_n (bn, b) (an, a)

(** assigns to each argument description its place in the original argument list
    @param args the arguments extracted from the annotation
    @param oargs the original arguments of the function call
    @return a [(int*arg_descr) list] where the int is the correct place in the
    argument list for the argument described in the arg_descr
 *)
let number_args (args: arg_descr list) (oargs: exp list) : (int*arg_descr) list =
  (* go through the list and for each argument keep the positions it
     appears in, these can be more than one i.e. Foo(a, b, a) *)
  let argstbl = H.create 16 in
  (* todo replace me with iteri in OCaml 4.0 *)
  let i = ref 0 in
  L.iter (fun expr ->
          let name = get_name_of_exp expr in
          let stack =
            try
              H.find argstbl name
            with Not_found -> (
              let stack = S.create () in
              H.add argstbl name stack;
              stack
            ) in
          S.push !i stack;
          incr i;
         ) oargs;
  (* Now for each argument in the pragma directive get it's position
     in the original function call *)
  L.map (fun arg ->
         let name = arg.aname in
         let i =
           try
             let stack = H.find argstbl name in
             S.pop stack
           with
           | S.Empty
           | Not_found -> (
               assert false
           )
         in
         (i, arg)
        ) args

(** Preprocesses a header file and merges it with a file.
    @param f the file to merge the header with
    @param include_dir the directory containing the header file
    @param header the header file name to merge
    @param args arguments to be passed to the preprocessor
 *) (* the original can be found in lockpick.ml *)
let preprocess_and_merge_header_x86 (f: file) (include_dir: string)
                                     (header: string) (args: string) : unit = (
  (* //Defining _GNU_SOURCE to fix "undefined reference to `__isoc99_sscanf'" *)
  ignore (Sys.command ("echo | gcc -E -D_GNU_SOURCE "^args^" -I"^include_dir^" "^include_dir^"/"^header^" - >/tmp/_cil_rewritten_tmp.h"));
  let add_h = Frontc.parse "/tmp/_cil_rewritten_tmp.h" () in
  let f' = Mergecil.merge [add_h; f] "stdout" in
  f.globals <- f'.globals;
)

(** Preprocesses a header file and merges it with a file.
    @param f the file to merge the header with
    @param header the header to merge
    @param def defines to be passed to the preprocessor
    @param incPath the include path to give to the preprocessor
 *) (* the original can be found in lockpick.ml *)
let preprocess_and_merge_header_cell (f: file) (header: string) (def: string)
    (incPath: string) : unit = (
  (* //Defining _GNU_SOURCE to fix "undefined reference to `__isoc99_sscanf'" *)
  ignore (Sys.command ("echo | ppu32-gcc -E "^def^" -I"^incPath^"/ppu -I"^incPath^"/spu "^header^" - >/tmp/_cil_rewritten_tmp.h"));
  let add_h = Frontc.parse "/tmp/_cil_rewritten_tmp.h" () in
  let f' = Mergecil.merge [add_h; f] "stdout" in
  f.globals <- f'.globals;
)

(** Prints {e msg} if {e flag} is true
  @param flag the debug flag
  @param msg the message to be printed
*)
let debug_print (flag: bool ref) (msg: string): unit = (
  if !flag then
    ignore(E.log "%s\n" msg);
)

class add_at_first_decl (gl_new: global list) : cilVisitor = object (self)
  inherit nopCilVisitor
  val mutable flag : bool = false

  method vglob glob =
    match glob with
      | GFun(_, _) when flag=false -> (
          flag <- true;
          ChangeTo (gl_new@[glob])
      )
      | GVarDecl(_, _) when flag=false -> (
          flag <- true;
          ChangeTo (gl_new@[glob])
      )
      | _ -> SkipChildren
  end

(** Adds a list of globals right BEFORE the first function definition
  @param f the file where we want to place the globals
  @param globals the list of the globals
 *)
let add_at_top (f: file) (globals: global list) : unit =
  let v = new add_at_first_decl globals in
  visitCilFile v f

(******************************************************************************)
(*                          Constructors                                      *)
(******************************************************************************)

(** takes an lvalue and a fieldname and returns lvalue.fieldname *)
let make_field_access lv fieldname =
  let lvt = Cil.typeOfLval lv in
  (* get the type *)
  let (lvtf, isptr) = match lvt with
    | TPtr(ty, _) -> (ty, true)
    | _ -> (lvt, false)
  in
  let ci = getCompinfo (unrollType lvtf) in
  let field = getCompField ci fieldname in
  addOffsetLval (Field (field, NoOffset)) (
    if isptr then (mkMem (Lval lv) NoOffset) else (lv)
  )

(** Defines the Task_table array for the spu file
    @param tasks the tasks to put in the task table
    @return the Task_table array as a Cil.global
 *)
let make_task_table (name: string) (tasks : (fundec * varinfo * (int * arg_descr) list) list) : global = (
  let etype = TPtr( TFun(TVoid([]), None, false, []), []) in
  let type' = TArray (etype, None, []) in
  let vi    = makeGlobalVar name type' in
  let n     = L.length tasks in
  let init' =
      let rec loopElems acc i =
        if i < 0 then acc
        else (
          let (_, task_vi, _) = L.nth tasks i in
          loopElems ( (Index(integer i, NoOffset), SingleInit(Lval (Var(task_vi), NoOffset))) :: acc) (i - 1)
        )
      in
      CompoundInit(etype, loopElems [] (n - 1))
  in
  let ii = {init = Some init'} in
  GVar(vi, ii, locUnknown)
)

(** Defines the Task_table for the ppu file. Simply filled with NULL
    @param tasks the tasks are just used to get the number of NULLS to put in the Task_table
    @return the Task_table array as a Cil.global
*)
let make_null_task_table (tasks : (fundec * varinfo * (int * arg_descr) list) list) : global = (
  let etype = TPtr( TFun(TVoid([]), None, false, []), []) in
  let type' = TArray (etype, None, []) in
  let vi    = makeGlobalVar "Task_table" type' in
  let n     = L.length tasks in
  let init' =
      let rec loopElems acc i =
        if i < 0 then acc
        else loopElems ((Index(integer i, NoOffset), makeZeroInit etype) :: acc) (i - 1)
      in
      CompoundInit(etype, loopElems [] (n - 1))
  in
  let ii = {init = Some init'} in
  GVar(vi, ii, locUnknown)
)

(** Defines a global variable with name name and type typ in file file
    @param name    The name of the new variable
    @param initial The initializer of the global variable
    @param typ     The type of the new variable
    @param file    The file in which the new variable will be defined
    @return the new variable as a Cil.varinfo
*)
let make_global_var name initial typ file=
  let v = makeGlobalVar name typ in
  let glob = GVar(v, {init = initial;}, locUnknown) in
  add_at_top file [glob];
  v


(******************************************************************************)
(*                         AttrParam to Expression                            *)
(******************************************************************************)

(* Type signatures. Two types are identical iff they have identical
 * signatures *)
let rec unrollSigtype (f:file) (ts: typsig) : typ =
  let unrollSigtype' = unrollSigtype f in
  match ts with
    TSArray (ts, Some i, attrs) -> TArray( unrollSigtype' ts, Some(kinteger64 IInt i), attrs )
  | TSArray (ts, None, attrs)   -> TArray( unrollSigtype' ts, None, attrs )
  | TSPtr (ts, attrs)  -> TPtr( unrollSigtype' ts, attrs )
  | TSComp (_, n, _ )  -> find_tcomp f n
  | TSFun (_, _, _, _) -> TVoid([]) (* Not sure about this :D *)
  | TSEnum (n, attrs)  -> TEnum(find_enum f n, attrs)
  | TSBase (t) -> t

(** exception returning the attribute that failed to convert into an expression *)
exception NotAnExpression of attrparam
(** Converts an attribute into an expression.
  @param  a the attrparam to convert
  @param  current_function the function we are currently processing
  @param  ppc_file  the ppc file
  @raise NotAnExpression when it fails
  @return the converted Cil.attrparam as a Cil.exp
 *)
let attrparam_to_exp (ppc_file: file) (loc: location) ?(currFunction: fundec = !current_function) (a: attrparam) : exp=
  assert (currFunction.svar.vname <> "@dummy");
  let rec subAttr2Exp (a: attrparam) : exp= (
    match a with
        AInt(i) -> integer i                    (** An integer constant *)
      | AStr(s) -> Const(CStr s)                (** A string constant *)
      | ACons(name, []) ->                    (** An id *)
          Lval (Var (find_scoped_var loc currFunction ppc_file name) , NoOffset)
      (* We don't support function calls as argument size *)
      | ACons(name, args) ->                 (** A function call *)
          E.s (errorLoc loc "Function calls (you are calling \"%s\") are not supported as argument size in #pragma css task..." name)
      | ASizeOf(t)       -> SizeOf t                  (** A way to talk about types *)
      | ASizeOfE(a)      -> SizeOfE (subAttr2Exp a)
      | ASizeOfS(ts)     -> SizeOf (unrollSigtype ppc_file ts)
      | AAlignOf(t)      -> AlignOf t
      | AAlignOfE(a)     -> AlignOfE (subAttr2Exp a)
      | AAlignOfS(ts)    -> AlignOf (unrollSigtype ppc_file ts)
      | AUnOp(op, a)     -> UnOp(op, subAttr2Exp a, intType) (* how would i know what type to put? *)
      | ABinOp(op, a, b) -> BinOp(op, subAttr2Exp a,
                                    subAttr2Exp b, intType) (* same as above *)
      | ADot(a, s) -> begin                    (** a.foo **)
        let predot = subAttr2Exp a in
        match predot with Lval(v) ->
            Lval (make_field_access v s)
          | _ -> raise (NotAnExpression a)
      end
      | AStar(a) -> Lval(mkMem (subAttr2Exp a) NoOffset) (** * a *)
      | AAddrOf(a) -> begin                                 (** & a **)
        let ar = subAttr2Exp a in
        match ar with Lval(v) ->
            mkAddrOf v
          | _ -> raise (NotAnExpression a)
      end
      | AIndex(a, i) -> begin                               (** a1[a2] *)
        let arr = subAttr2Exp a in
        match arr with Lval(v) ->
            Lval(addOffsetLval (Index(subAttr2Exp i, NoOffset)) v)
          | _ -> raise (NotAnExpression a)
      end
      (* not supported *)
  (*    | AQuestion of attrparam * attrparam * attrparam (** a1 ? a2 : a3 **)*)
      | AQuestion (at1, at2, at3) ->
          E.s (errorLoc loc "\"cond ? if : else\"  is not supported in #pragma css task...")
  ) in
  subAttr2Exp a


(******************************************************************************)
(*                         Function call generator                            *)
(******************************************************************************)
let make_func_call (f: file) (loc : location) (s: stmt) (exps: attrparam list)
                   (func: string): stmt visitAction =
  (* find wait_on functions declaration *)
  let func  = find_function_sign f func in
  (* prepare the arguments *)
  let args  = L.map (attrparam_to_exp f loc) exps in
  (* create the call *)
  let instr = Call (None, Lval (var func), args, locUnknown) in
  (* pop out the processed pragma *)
  let s'    = {s with pragmas = List.tl s.pragmas} in
  (* push the generated code *)
  ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)


(******************************************************************************)
(*                             Argument processor                             *)
(******************************************************************************)

(** processes recursively the arguments' info found in in() out() and
    inout() directives *)
let rec scoop_process_args size_in_bytes ppc_file typ loc args : arg_descr list =
  let attrparam_to_exp'  = attrparam_to_exp ppc_file loc in
  let arg_f              = arg_flow_of_string typ loc in
  let scoop_process_args = scoop_process_args size_in_bytes ppc_file typ loc in
  match args with
  (* Brand new stride syntax... *)
  | (AIndex(AIndex(ACons(varname, []), ABinOp( BOr, bs_r, bs_c)), orig)::rest) ->
    (* Brand new stride syntax with optional 2nd dimension of the original array... *)
    let orig_c =
      match orig with
      | ABinOp( BOr, _, orig_c) -> orig_c
      | _ -> orig
    in
    let vi         = find_scoped_var loc !current_function ppc_file varname in
    let tmp_addr   = Lval(var vi) in
    let size       = SizeOf( get_basetype vi.vtype vi.vname ) in
    let tmp_bs_c   = attrparam_to_exp' bs_c in
    (* block's row size = bs_c * sizeof(type) *)
    let tmp_bs_c   = BinOp(Mult, tmp_bs_c, size, intType) in
    let tmp_bs_r   = attrparam_to_exp' bs_r in
    let tmp_orig_c = attrparam_to_exp' orig_c in
    (* original array row size = orig_c * sizeof(type) *)
    let tmp_orig_c = BinOp(Mult, tmp_orig_c, size, intType) in
    let tmp_t      = Stride(arg_f, tmp_orig_c, tmp_bs_r, tmp_bs_c) in
    { aname=varname; address=tmp_addr; atype=tmp_t;}::(scoop_process_args rest)
  (* handle strided (legacy) ... *) (* Check documentation for the syntax *)
  | (AIndex(AIndex(ACons(varname, []), varsize), ABinOp( BOr, var_els, var_elsz))::rest) ->
    let vi       = find_scoped_var loc !current_function ppc_file varname in
    let tmp_addr = Lval(var vi) in
    let tmp_size = attrparam_to_exp' varsize in
    let tmp_els  = attrparam_to_exp' var_els in
    let tmp_elsz = attrparam_to_exp' var_elsz in
    let tmp_t    = Stride(arg_f, tmp_size, tmp_els, tmp_elsz) in
    { aname=varname; address=tmp_addr; atype=tmp_t;}::(scoop_process_args rest)
  (* variable with its size *)
  | (AIndex(ACons(varname, []), varsize)::rest) ->
    let vi       = find_scoped_var loc !current_function ppc_file varname in
    let tmp_addr = Lval(var vi) in
    let tmp_size =
      if (size_in_bytes) then
        attrparam_to_exp ppc_file loc varsize
      else (
        let size = SizeOf( get_basetype vi.vtype vi.vname ) in
        let n    = attrparam_to_exp ppc_file loc varsize in
        (* argument size = n * sizeof(type) *)
        BinOp(Mult, n, size, intType)
      )
    in
    let tmp_t =
      if (is_scalar_v vi) then
        Scalar(arg_f, tmp_size)
      else
        Normal(arg_f, tmp_size)
    in
    { aname=varname; address=tmp_addr; atype=tmp_t;}::(scoop_process_args rest)
  (* support optional sizes example int_a would have size of sizeof(int_a) *)
  | (ACons(varname, [])::rest) ->
    let vi       = find_scoped_var loc !current_function ppc_file varname in
    let tmp_addr = Lval(var vi) in
    let tmp_size = SizeOf( get_basetype vi.vtype vi.vname ) in
    let tmp_t    =
      if (is_scalar_v vi) then
        Scalar(arg_f, tmp_size)
      else
        Normal(arg_f, tmp_size)
    in
    { aname=varname; address=tmp_addr; atype=tmp_t;}::(scoop_process_args rest)
  | [] -> []
  | _ -> E.s (errorLoc loc "Syntax error in #pragma ... task %s(...)\n" typ)
