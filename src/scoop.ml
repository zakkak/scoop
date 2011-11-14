(*
 *
 * Copyright (c) 2010, 
 *  Foivos Zakkak        <zakkak@ics.forth.gr>
 *  Polyvios Pratikakis <polyvios@ics.forth.gr>
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 * 1. Redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * 3. The names of the contributors may not be used to endorse or promote
 * products derived from this software without specific prior written
 * permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
 * IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER
 * OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 *)

(** The main module of SCOOP *)

open Pretty
open Cil
open Lockutil
open Scoop_util
open Scoop_make_exec
open Scoop_x86
module E = Errormsg
module H = Hashtbl
module S = Str
module L = List
module T = Trace
module CG = Callgraph
module Lprof = Lockprofile

(* defining some Trace shortcuts *)
(*let trace = T.trace "scoop"
let tracei = T.tracei "scoop"
let traceu = T.traceu "scoop"*)

(* defining globals *)
(** holds the TPC's SPEs queue size *)
let queue_size = ref "0"
(** flag for more prints by SCOOP *)
let debug = ref false
(** flag for some tracing prints of SCOOP *)
(*let dotrace = ref false*)
(** flag to support multithreading or not *)
let thread = ref false
(** the prefix of the files to be produced by SCOOP. Defaults to "final" *)
let out_name = ref "final"
(** the runtime/architecture to target. Currently supporting cell/cellgod.
    Defaults to unknown *)
let arch = ref "unknown"
(** the path where the runtime headers are located *)
let tpcIncludePath = ref ""
(** flags to pass to the gcc when merging files *)
let cflags = ref ""
(** holds the previous visited statement *)
let prevstmt = ref dummyStmt
let dis_sdam = ref false

let blade = ref false

(** The new spu file to create *)
let spu_file = ref dummyFile
(** The new ppu file to create *)
let ppc_file = ref dummyFile

(** the options supported by scoop *)
let options =
  [
    "--runtime",
      Arg.String(fun s -> arch := s),
      " SCOOP: Define the target runtime/architecture (x86/cell/cellgod/cellBlade/cellgodBlade/XPPFX).";

    "--cflags",
      Arg.String(fun s -> cflags := s),
      " SCOOP: Define the flags you want to pass to gcc.";

    "--tpcIncludePath",
      Arg.String(fun s -> tpcIncludePath := s),
      " SCOOP: Define the include path for the tpc runtime.";

    "--debugSCOOP",
      Arg.Set(debug),
      " SCOOP: Print debugging information.";

(*    "--trace",
      Arg.Set(dotrace),
      " SCOOP: Trace SCOOP.";*)

    "--out-name",
      Arg.String(fun s -> out_name := s),
      " SCOOP: Specify the output files' prefix. e.g. (default: final) will produce final.c (and final_func.c for cell)";

    "--queue-size",
      Arg.String(fun s -> queue_size := s),
      " SCOOP: Specify the queue size for Cell. Defined in the Makefile as MAX_QUEUE_ENTRIES";

    "--with-stats",
      Arg.Set(stats),
      " SCOOP: Enable code for statistics, for use with -DSTATISTICS";

    "--with-unaligned-arguments",
      Arg.Set(unaligned_args),
      " SCOOP: Allow unalligned arguments in x86, for use with -DUNALIGNED_ARGUMENTS_ALLOWED";

(*    "--without-blocking",
      Arg.UnSet(blocking),
      " SCOOP: Enable blocking arguments in x86. for use with -DBLOCKING";*)

    "--threaded",
      Arg.Set(thread),
      " SCOOP: Generate thread safe code for Cell, for use with -DTPC_MULTITHREADED";

    "--disable-sdam",
      Arg.Set(dis_sdam),
      " SCOOP: Disable the static dependence analysis module";
  ]

(* create 1 global list (the spe output file) *)
(** holds the processed tasks *)
let spu_tasks = ref []

(** processes recursively the arguments' info found in input() output() and
    inout() directives *)
let rec scoop_process_args typ args loc : arg_descr list =
  let attrParamToExp' = attrParamToExp !ppc_file loc in
  match args with
    (* Brand new stride syntax... *)
    (AIndex(AIndex(ACons(varname, []), ABinOp( BOr, bs_r, bs_c)), orig)::rest) ->
      (* Brand new stride syntax with optional 2nd dimension of the original array... *)
      let orig_c = 
        match orig with
          ABinOp( BOr, _, orig_c) -> orig_c
          | _ -> orig
      in
      let vi = find_scoped_var loc !currentFunction !ppc_file varname in
      let tmp_addr = Lval(var vi) in
      let size = SizeOf( getBType vi.vtype vi.vname ) in
      let tmp_bs_c = attrParamToExp' bs_c in
      (* block's row size = bs_c * sizeof(type) *)
      let tmp_bs_c = BinOp(Mult, tmp_bs_c, size, intType) in
      let tmp_bs_r = attrParamToExp' bs_r in
      let tmp_orig_c = attrParamToExp' orig_c in
      (* original array row size = orig_c * sizeof(type) *)
      let tmp_orig_c = BinOp(Mult, tmp_orig_c, size, intType) in
      (varname, (tmp_addr, (translate_arg typ true loc),
          tmp_orig_c, tmp_bs_c, tmp_bs_r))::(scoop_process_args typ rest loc)
    (* handle strided (legacy) ... *) (* Check documentation for the syntax *)
   | (AIndex(AIndex(ACons(varname, []), varsize), ABinOp( BOr, var_els, var_elsz))::rest) ->
      let tmp_addr = Lval(var (find_scoped_var loc !currentFunction !ppc_file varname)) in
      let tmp_size = attrParamToExp' varsize in
      let tmp_els = attrParamToExp' var_els in
      let tmp_elsz = attrParamToExp' var_elsz in
      (varname, (tmp_addr, (translate_arg typ true loc),
          tmp_size, tmp_els, tmp_elsz))::(scoop_process_args typ rest loc)
   (* variable with its size *)
   | (AIndex(ACons(varname, []), varsize)::rest) ->
      let tmp_addr = Lval(var (find_scoped_var loc !currentFunction !ppc_file varname)) in
      let tmp_size = attrParamToExp !ppc_file loc varsize in
      (varname, (tmp_addr, (translate_arg typ false loc),
          tmp_size, tmp_size, tmp_size))::(scoop_process_args typ rest loc)
    (* support optional sizes example int_a would have size of sizeof(int_a) *)
   | (ACons(varname, [])::rest) ->
      let vi = find_scoped_var loc !currentFunction !ppc_file varname in
      let tmp_addr = Lval(var vi) in
      let tmp_size = SizeOf( getBType vi.vtype vi.vname ) in
      (varname, (tmp_addr, (translate_arg typ false loc),
          tmp_size, tmp_size, tmp_size))::(scoop_process_args typ rest loc)
    | [] -> []
    | _ -> ignore(warnLoc loc "Syntax error in #pragma css task %s(...)\n" typ); []

(** parses the #pragma css task arguments *)
let rec scoop_process pragma loc =
  match pragma with
    (AStr("highpriority")::rest) ->
      let (_, lst) = scoop_process rest loc in
      (true, lst)
    | (ACons(arg_typ, args)::rest) ->
      let (hp, lst) = scoop_process rest loc in
      (* kasas' mess here *)
      (* ignore safe tags, it's a hint for the analysis *)
      if(not (is_dataflow_tag arg_typ)) then 
      	(hp, lst)
      else
      	(hp, (scoop_process_args arg_typ args loc)@lst)
    | [] -> (false, [])
    | _ -> ignore(warnLoc loc "Syntax error in #pragma css task\n"); (false, [])

(** populates the global list of spu tasks [spu_tasks] *)
class findSPUDeclVisitor cgraph = object
  inherit nopCilVisitor
  val callgraph = cgraph 
  (* visits all stmts and checks for pragma directives *)
  method vstmt (s: stmt) : stmt visitAction =
    (*ignore(match s.skind with 
      Instr(Call(_, Lval((Var(vi), _)), args, _)::_) ->
        L.iter (fun a -> ignore(E.log "arg= %a\n" d_exp a)) args;
      | _ -> (););*)
(*     print_endline ("Now in "^(!currentFunction).svar.vname); *)
(* if ((!currentFunction).svar.vname="ComputeLikelihood") then *)
(*     (dumpStmt defaultCilPrinter stdout 2 s); *)
(*     print_endline (""); *)
    let prags = s.pragmas in
    if (prags <> []) then (

      match (List.hd prags) with
        (* Support #pragma css ... *)
        (Attr("css", rest), loc) -> (
          match rest with
          (* Support #pragma css wait on(...) *)
            AStr("wait")::(ACons("on", exps)::_) -> (
              if (!arch = "XPPFX") then (
                let two = find_function_sign (!ppc_file) "tpc_wait_on" in
                let args = []
                 (* if (!arch="cell") then
                    [attrParamToExp !ppc_file loc exp]
                  else if (!arch="cellgod") then
                    attrParamToExp !ppc_file loc exp::[attrParamToExp !ppc_file loc (L.hd rest)]
                  else (
                    match rest with
                      first::second::_ -> attrParamToExp !ppc_file loc exp::(attrParamToExp !ppc_file loc first::[attrParamToExp !ppc_file loc second])
                      | _ -> E.s (errorLoc loc "#pragma css start takes 3 arguments")
                  ) *)
                in
                let instr = Call (None, Lval (var two), args, locUnknown) in
                let s' = {s with pragmas = List.tl s.pragmas} in
                ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)
              ) else (* TODO wait on *)
                DoChildren
          )
          (* Support #pragma css wait all *)
          | AStr("wait")::(AStr("all")::_)
          (* Support #pragma css barrier*)
          | AStr("barrier")::_ -> (
            let twa = find_function_sign (!ppc_file) "tpc_wait_all" in
            let instr = Call (None, Lval (var twa), [], locUnknown) in
            let s' = {s with pragmas = List.tl s.pragmas} in
            ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)
          )
          (* Support #pragma css start *)
          | AStr("start")::_
          (* Support #pragma css start(...) *)
          | ACons("start", [])::_ -> (
            let ts = find_function_sign (!ppc_file) "tpc_init" in
            let instr = Call (None, Lval (var ts), [], locUnknown) in
            let s' = {s with pragmas = List.tl s.pragmas} in
            ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)
          )
          | ACons("start", exp::rest)::_ -> (
            let ts = find_function_sign (!ppc_file) "tpc_init" in
            let args =
              if (!arch="cell") then
                [attrParamToExp !ppc_file loc exp]
              else if (!arch="cellgod") then
                attrParamToExp !ppc_file loc exp::[attrParamToExp !ppc_file loc (L.hd rest)]
              else (
                match rest with
                  first::second::_ -> attrParamToExp !ppc_file loc exp::(attrParamToExp !ppc_file loc first::[attrParamToExp !ppc_file loc second])
                  | _ -> E.s (errorLoc loc "#pragma css start takes 3 arguments")
              )
            in
            let instr = Call (None, Lval (var ts), args, locUnknown) in
            let s' = {s with pragmas = List.tl s.pragmas} in
            ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)
          )
          (* Support #pragma css finish *)
          | AStr("finish")::_ -> (
            let ts = find_function_sign (!ppc_file) "tpc_shutdown" in
            let instr = Call (None, Lval (var ts), [], locUnknown) in
            let s' = {s with pragmas = List.tl s.pragmas} in
            ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)
          )
          (* Support #pragma css malloc *)
          | AStr("malloc")::_ -> (
            let tm = find_function_sign (!ppc_file) "tpc_malloc" in
            match s.skind with
                Instr(Call(Some res, Lval((Var(vi), _)), oargs, loc)::restInst) -> (


                  let instr = Call (Some res, Lval (var tm), oargs, locUnknown) in
                  ChangeTo(mkStmtOneInstr instr)
                )
              | _ -> DoChildren
          )
          (* Support #pragma css free *)
          | AStr("free")::_ -> (
            let tf = find_function_sign (!ppc_file) "tpc_free" in
            match s.skind with
                Instr(Call(_, Lval((Var(vi), _)), oargs, loc)::restInst) -> (


                  let instr = Call (None, Lval (var tf), oargs, locUnknown) in
                  ChangeTo(mkStmtOneInstr instr)
                )
              | _ -> DoChildren
          )
          (* Support #pragma css task... *)
          | AStr("task")::rest -> (
            match s.skind with
            Instr(Call(_, Lval((Var(vi), _)), oargs, loc)::restInst) -> (
              let funname = vi.vname in
              let (is_hp, args) = scoop_process rest loc in
              dbg_print debug ("Found task \""^funname^"\"");
              if (!arch = "x86" || !arch = "XPPFX") then (

                let check (name, _) =
                  if ( not (L.exists (fun e ->
                    if ((getNameOfExp e)=name) then
                      true
                    else (
                      false
                    )
                  ) oargs)) then (
                    let args_err = ref "(" in
                    List.iter (fun e -> args_err := ((!args_err)^" "^(getNameOfExp e)^",") ) oargs;
                    E.s (errorLoc loc "#1 Argument \"%s\" in the pragma directive not found in %s )" name !args_err);
                  ) in
                L.iter check args;

                let rest_f2 var_i =
                  (* select the function to create the issuer *)
                  let make_tpc_issuef = match !arch with
                      "x86" -> Scoop_x86.make_tpc_issue is_hp
                    | _ (*"XPPFX"*) -> Scoop_XPPFX.make_tpc_issue is_hp
                  in
                  let (stmts, args) = make_tpc_issuef loc var_i oargs args !ppc_file !currentFunction in
                  spu_tasks := (funname, (dummyFunDec, var_i, args))::!spu_tasks;
                  ChangeTo(mkStmt (Block(mkBlock stmts)) )
                in
                (* try to find the function definition *)
                try
                  (* checking for the function definition *)
                  let task = find_function_fundec_g (!ppc_file.globals) funname in
                  rest_f2 task.svar
                (* else try to find the function signature/prototype *)
                with Not_found -> (
                  let task = find_function_sign (!ppc_file) funname in
                  rest_f2 task
                )
              ) else (
                let rest_f new_fd =
                  (* add arguments to the call *)
                  let call_args =
                    let expS2P = expScalarToPointer loc in
                    ref (L.rev (L.map expS2P oargs))
                  in

                  (* for each actual argument of the call find it's (pragma)
                      declared size and push it to the argument list of the
                      new call *)
                  let rec getSizeNstride = function
                    | Lval ((Var(vi),_))
                    | StartOf ((Var(vi),_)) -> (
                      try
                        let (arg_addr, arg_type, vsize, velsz, vels) = L.assoc vi.vname args in
                        call_args := vsize::!call_args;
                        if (is_strided arg_type) then (
                          call_args := velsz::!call_args;
                          call_args := vels::!call_args;
                        );
                      with Not_found ->
                        E.s (errorLoc loc "You probably forgot to add \"%s\" in the pragma directive\n" vi.vname)
                    )
                    | CastE (_, ex') -> getSizeNstride ex';
                    (* The following are not supported yet *)
                    | Const _ -> raise (Invalid_argument "Const");
                    | SizeOf _ -> raise (Invalid_argument "Sizeof");
                    | SizeOfE _ -> raise (Invalid_argument "SizeofE");
                    | SizeOfStr _ -> raise (Invalid_argument "SizeofStr");
                    | AlignOf _ -> raise (Invalid_argument "Alignof");
                    | AlignOfE _ -> raise (Invalid_argument "AlignOfE");
                    | UnOp _ -> raise (Invalid_argument "UnOp");
                    | BinOp _ -> raise (Invalid_argument "BinOp");
                    | AddrOf _ -> raise (Invalid_argument "AddrOf");
                    | _ -> raise (Invalid_argument "Uknown");
                  in
                  L.iter getSizeNstride oargs;

                  let instr = Call (None, Lval (var new_fd.svar), L.rev !call_args, locUnknown) in
                  let call = mkStmt (Instr(instr::restInst)) in
                  ChangeTo(call)
                in
                try
                  (* fast workaround *)
                  if (!arch = "cell" ) then
                    (* check if we have seen this function before *)
                    let (new_fd, _, _) = List.assoc funname !spu_tasks in
                    rest_f new_fd
                  else
                    raise Not_found
                with Not_found -> (
                  let rest_f2 var_i =
                    (* select the function to create the custom tpc_calls *)
                    let make_tpc_funcf = match !arch with
                        "cell" -> Scoop_cell.make_tpc_func
                      | _ (*"cellgod"*) -> Scoop_cellgod.make_tpc_func
                    in
                    let (new_fd, args) = make_tpc_funcf loc var_i oargs args ppc_file spu_file in
                    add_after_s !ppc_file var_i.vname new_fd;
                    spu_tasks := (funname, (new_fd, var_i, args))::!spu_tasks;
                    rest_f new_fd
                  in
                  (* try to find the function definition *)
                  try
                    (* checking for the function definition *)
                    let task = find_function_fundec_g (!ppc_file.globals) funname in
                    (* copy itself and the callees *)
                    deep_copy_function funname callgraph !spu_file !ppc_file;
                    rest_f2 task.svar
                  (* else try to find the function signature/prototype *)
                  with Not_found -> (
                    let task = find_function_sign (!ppc_file) funname in
                    rest_f2 task
                  )
                )
              )
            )
            | Block(b) -> ignore(unimp "Ignoring block pragma"); DoChildren
            | _ -> dbg_print debug "Ignoring pragma"; DoChildren
          )
          (* warn about ignored #pragma css ... directives *)
          | _ -> ignore(warnLoc loc "Ignoring #pragma %a\n" d_attr (Attr("css", rest))); DoChildren
        )
        | (_, loc) -> dbg_print debug (loc.file^":"^(string_of_int loc.line)^" Ignoring #pragma directive"); DoChildren
    ) else 
      DoChildren
end

let feature : featureDescr = 
  { fd_name = "findspucode";
    fd_enabled = ref true;
    fd_description = "find all pragmas declaring spu tasks";
    fd_extraopt = options
    @ Uniqueness.options
    @ Locksettings.options
    (*@ Livevars.options*)
    @ Shared.options
    @ Correlation.options
    @ Controlflow.options
    @ Bansheemlifc.options
    @ Labelflow.options
    @ Lprof.options
    ;
    fd_doit = 
    (function (f: file) ->
(*      if !dotrace then
        Trace.traceAddSys "scoop";*)
      dbg_print debug "\nWelcome to SCOOP!!!\n";

      if (!arch = "unknown") then
        E.s (error "No architecture specified. Exiting!")
      else if (!arch = "cell" && !queue_size = "0") then
        E.s (error "No queue_size specified. Exiting!")
      else (
        if(!arch = "cellBlade") then (
          blade := true;
          arch := "cell";
        ) else if(!arch = "cellgodBlade") then (
          blade := true;
          arch := "cellgod";
        );

        (* if we are not on x86-SMP create two copies of the initial file *)
        if (!arch <> "x86" && !arch <> "XPPFX") then
          spu_file := { dummyFile with fileName = (!out_name^"_func.c");};
        ppc_file := { f with fileName = (!out_name^".c");};

        (* create a call graph and print it *)
        let callgraph = CG.computeGraph f in


        (* find tpc_decl pragmas *)
        let fspuVisitor = new findSPUDeclVisitor callgraph in
        (* let ftagVisitor = new findTaggedCalls in *)

        (* create a global list (the spu output file) *)
  (*       let spu_glist = ref [] in *)

        let def = " "^(!cflags)^
          ( if (!stats) then " -DSTATISTICS=1" else " ")^
          ( if (!blade) then " -DBLADE=1" else " ") in
        if (!arch = "x86") then (
          preprocessAndMergeWithHeader_x86 !ppc_file ((!tpcIncludePath)^"/scoop/tpc_scoop.h") (def);
        ) else if (!arch = "XPPFX") then (
          preprocessAndMergeWithHeader_x86 !ppc_file ((!tpcIncludePath)^"/XPPFX_header.h") (def);
        ) else ( (* else cell/cellgod *)
          (* copy all code from file f to file_ppc *)
          let def = def^(
            if (!arch = "cellgod") then 
              (" -DADAM=1")
            else
              (" -DMAX_QUEUE_ENTRIES="^(!queue_size))
          ) in

          (* Defined in scoop_util *)
          preprocessAndMergeWithHeader_cell !ppc_file ((!tpcIncludePath)^"/scoop/tpc_scoop.h") (" -DPPU=1"^(def))
                                      !tpcIncludePath;

          (* copy all typedefs and enums/structs/unions from ppc_file to spu_file
            plus the needed headers *)
          let new_types_l = List.filter is_typedef (!ppc_file).globals in
          (!spu_file).globals <- new_types_l;
          preprocessAndMergeWithHeader_cell !spu_file ((!tpcIncludePath)^"/scoop/tpc_scoop.h") (" -DSPU=1"^(def))
                                      !tpcIncludePath;
        );

        (* Declare some globals *)
        let globals = ref [] in
        let makeGlobalVar ini n t =
          globals := GVar(makeGlobalVar n t, {init = ini;}, locUnknown)::!globals;
        in
        (match !arch with
          (* Task_element *this;
             uint32_t block_index_start
             uint64_t e_addr;
             uint64_t _tmptime; *)
          "x86" -> (
            let makeGlobalVar = makeGlobalVar None in
            let task_element_pt = TPtr((find_type !ppc_file "Task_element"), []) in
            makeGlobalVar "this_SCOOP__" task_element_pt;
            let uint32_t = (find_type !ppc_file "uint32_t") in
            let uint64_t = (find_type !ppc_file "uint64_t") in
            makeGlobalVar "block_index_start_SCOOP__" uint32_t;
            makeGlobalVar "e_addr_SCOOP__" uint64_t;
            makeGlobalVar "_tmptime1_SCOOP__" uint64_t;
            makeGlobalVar "_tmptime2_SCOOP__" uint64_t;
          )
          (* const int tpc_task_arguments_list[]; *)
          | "XPPFX" -> (
            makeGlobalVar (Some (SingleInit(zero))) "tpc_task_arguments_list" (TArray(TInt(IInt, [Attr("const", [])]), None, []));
          )
          (* cell and cellgod do better with functions due to small memory *)
          (* volatile queue_entry_t *avail_task=NULL;
            #ifdef STATISTICS
              uint64_t tmptime1, tmptime2, tmptime3;
              unsigned int total_bytes=0;
            #endif
            int *task_id_qs, task_id;

            volatile struct completions_status_t *st; *)
(*          | "cell" -> (
            let queue_entry_pt = TPtr((find_type !ppc_file "queue_entry_t"), [Attr("volatile", [])]) in
            makeGlobalVar "avail_task_SCOOP__" task_element_t;
            if (!stats) then (
              let uint64_t = (find_tcomp !ppc_file "uint64_t") in
              makeGlobalVar "tmptime1_SCOOP__" uint64_t;
              makeGlobalVar "tmptime2_SCOOP__" uint64_t;
              makeGlobalVar "tmptime3_SCOOP__" uint64_t;
              makeGlobalVar "total_bytes_SCOOP__" uintType;
            )
            makeGlobalVar "task_id_qs_SCOOP__" TPtr(intType, []);
            makeGlobalVar "task_id_SCOOP__" intType;
          )*)
          (* Task_element *this; *)
(*          | "cellgod" -> (
            let task_element_pt = TPtr((find_type !ppc_file "Task_element"), []) in
            makeGlobalVar "this_SCOOP__" task_element_t;
          )*)
          | _ -> ()
        );
        add_at_top !ppc_file !globals;

        (* SDAM *)
        if (!arch <> "cell") then
          (Ptdepa.find_dependencies f !dis_sdam);

        Cil.iterGlobals !ppc_file
          (function
            GFun(fd,_) ->
              currentFunction := fd;
              ignore(visitCilFunction fspuVisitor fd);
          | _ -> ()
          )
        ;

        (* copy all globals except the function declaration of "tpc_call_tpcAD65" *)
        (!ppc_file).globals <- List.filter isNotSkeleton (!ppc_file).globals;
        (* copy all globals except the function declaration of "main" *)
  (*       spu_glist := List.filter isNotMain (!spu_file).globals; *)


        (* tasks  (new_tpc * old_original * args) *)
        let tasks : (fundec * varinfo * (int * arg_descr) list) list = List.map
          (fun (name, (new_fd, old_fd, args)) -> (new_fd, old_fd, args))
          (L.rev !spu_tasks)
        in
        if (!arch = "cellgod") then (
          (!ppc_file).globals <- (make_null_task_table tasks)::((!ppc_file).globals);
          (!spu_file).globals <- (!spu_file).globals@[(make_task_table tasks)]
        ) else if (!arch = "x86") then (
          (!ppc_file).globals <- ((!ppc_file).globals)@[(make_task_table tasks)]
        );

        (* execute_task is redundant in x86*)
        if (!arch <> "x86" && !arch <> "XPPFX") then
          (!spu_file).globals <- (!spu_file).globals@[make_exec_func !arch !spu_file tasks];

        (* eliminate dead code *)
(*        Cfg.computeFileCFG !ppc_file;
        Deadcodeelim.dce !ppc_file;
        Cfg.computeFileCFG !spu_file;
        Deadcodeelim.dce !spu_file;*)

(*         Scoop_rmtmps.removeUnused !ppc_file; *)
        writeFile !ppc_file;
        if (!arch <> "x86" && !arch <> "XPPFX") then
          writeFile !spu_file;
      )
    );
    fd_post_check = true;
  }
