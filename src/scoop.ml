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

open Pretty
open Cil
open Lockutil
open Scoop_util
open Scoop_x86
open Scoop_cell
module E = Errormsg
module H = Hashtbl
module S = Str
module L = List
module T = Trace
module CG = Callgraph
module Lprof = Lockprofile

(* defining some Trace shortcuts *)
let trace = T.trace "scoop"
let tracei = T.tracei "scoop"
let traceu = T.traceu "scoop"

(* defining globals *)
let queue_size = ref "0"
let debug = ref false
let dotrace = ref false
let thread = ref false
let out_name = ref "final"
let arch = ref "unknown"
let tpc_include_path = ref (try
  Unix.getenv "TPC_INCLUDE_PATH"
  with Not_found -> ".")
let cflags = ref ""
let prevstmt = ref dummyStmt

(* create a ref to the input file *)
(* let in_file = ref dummyFile *)
(* create a ref to the new spu file *)
let spu_file = ref dummyFile
(* create a ref to the new ppe file *)
let ppc_file = ref dummyFile

let options =
  [
    "--runtime",
      Arg.String(fun s -> arch := s),
      " SCOOP: Define the target runtime/architecture (x86/cell/cellgod).";

    "--cflags",
      Arg.String(fun s -> cflags := s),
      " SCOOP: Define the flags you want to pass to gcc.";

    "--tpcIncludePath", (* FIXME: rename to used option style: --tpc-include-path *)
      Arg.String(fun s -> tpc_include_path := s),
      " SCOOP: Define the include path for the tpc runtime.";

    "--debugSCOOP",
      Arg.Set(debug),
      " SCOOP: Print debugging information.";

    "--trace",
      Arg.Set(dotrace),
      " SCOOP: Trace scoop compiler.";

    "--out-name",
      Arg.String(fun s -> out_name := s),
      " SCOOP: Specify the output files' prefix. e.g. (default: final) will produce final.c and final_func.c";

    "--queue-size",
      Arg.String(fun s -> queue_size := s),
      " SCOOP: Specify the queue size for Cell. Defined in the Makefile as MAX_QUEUE_ENTRIES";

    "--block-size",
      Arg.Int(fun s -> Scoop_x86.block_size := s),
      " SCOOP: Specify the block size for the ADAM runtime. Defined in the Makefile as BLOCK_SZ";

    "--with-stats",
      Arg.Set(stats),
      " SCOOP: Enable code for statistics, for use with -DSTATISTICS";

    "--with-unaligned-arguments",
      Arg.Set(unaligned_args),
      " SCOOP: Allow unalligned arguments in x86, for use with -DUNALIGNED_ARGUMENTS_ALLOWED";

    "--with-blocking",
      Arg.Set(blocking),
      " SCOOP: Enable bocking arguemts. for use with -DBLOCKING";

    "--threaded",
      Arg.Set(thread),
      " SCOOP: Generate thread safe code, for use with -DTPC_MULTITHREADED";
  ]

(* create 1 global list (the spe output file) *)
let spu_tasks = ref []

(*
(* parses the #pragma css task arguments and pushes them to ptdepa *)
let rec ptdepa_process_args typ args : unit =
  if ( args <> []) then (
    match (L.hd args) with
      AIndex(ACons(varname, []), varsize) -> (
        trace (dprintf "pushing %s\n" varname);
        Ptdepa.addArg (varname, typ, !currentFunction);
      )
      | _ -> ignore(E.warn "Syntax error in #pragma tpc task %s(...)\n" typ);
    ptdepa_process_args typ (L.tl args)
  )

let rec ptdepa_process = function
  | (cur::rest) -> (
    match cur with
      AStr("highpriority") -> (* simply ignore it *) ();
      | ACons(arg_typ, args) -> (
        tracei (dprintf "pushing args of function %s to ptdepa!\n" (!currentFunction).svar.vname);
        ptdepa_process_args arg_typ args;
        T.traceOutdent "scoop"
      )
      | _ -> ignore(E.warn "Syntax error in #pragma tpc task\n");
    ptdepa_process rest
  )
  | _ -> ()

(* populates the calls list for Ptdepa module *)
class findTaggedCalls = object
  inherit nopCilVisitor
  (* visits all stmts and checks for pragma directives *)
  method vstmt (s: stmt) : stmt visitAction =
    let prags = s.pragmas in
    if (prags <> []) then (
      match (List.hd prags) with
        (Attr("css", sub::rest), loc) -> (
          match sub with
            AStr("task") -> (
              match s.skind with 
                Instr(Call(_, Lval((Var(vi), _)), _, loc)::_) -> (
                  ptdepa_process rest;
                  trace (dprintf "adding task %s to ptdepa\n" vi.vname);
                  Ptdepa.addTask vi.vname !currentFunction loc;
                )
                | Block(b) -> ignore(E.warn "Ignoring block pragma at %a" d_loc loc);
                | _ -> ignore(E.warn "Ignoring pragma at %a" d_loc loc);
            )
            | _ -> ignore(E.warn "Ptdepa: Ignoring pragma at %a" d_loc loc);
        )
        | (Attr("tpc", args), _) -> (
          match s.skind with 
            Instr(Call(_, Lval((Var(vi), _)), _, loc)::_) -> (
                tracei (dprintf "pushing args of function %s to ptdepa!\n" vi.vname);
                ignore(List.map (fun arg -> match arg with
                    ACons(varname, ACons(arg_typ, [])::ACons(varsize, [])::_) -> 
                      (* give all the arguments to Ptdepa don't care for strided  *)
                      trace (dprintf "pushing %s\n" varname);
                      Ptdepa.addArg (varname, arg_typ, !currentFunction);
                  | _ -> ignore(E.error "You have done something wrong at %a\n" d_loc loc); assert false
                ) args);
                T.traceOutdent "scoop";
                trace (dprintf "adding task %s to ptdepa\n" vi.vname);
                Ptdepa.addTask vi.vname !currentFunction loc;
              )
            | Block(b) -> ignore(E.unimp "Ignoring block pragma");
            | _ -> ignore(E.warn "Ignoring pragma");
        )
        | _ -> ignore(E.log "Unrecognized pragma");
     ) else (
       (* Get info about array indices from loops *)
       match s.skind with
          Loop(b_code, _, _, _) -> (
            (* Check if there is any task inside the loop *)
            let tagged_stmts = L.filter tpc_call_with_arrray b_code.bstmts in
            if (tagged_stmts<>[]) then (
              let successor = get_loop_successor s in
              let upper = get_loop_condition s in
              let lower = get_loop_lower s !prevstmt in
              ignore(E.log "\tlower=%a\n\tupper=%a\n\tsucc=%a\n" d_exp lower d_exp upper d_exp successor);
              (*for each call
                let indice = get_indice tagged_stmt in*)
              (* visit the b_code.bstmts to find the Upper and the successor function *)
            )
          )
          | _ -> ()
    );
    prevstmt := s;
    DoChildren
end
*)

(* parses the #pragma css task arguments *)
let rec scoop_process_args typ args =
  match args with
    (AIndex(ACons(varname, []), varsize)::rest) ->
      let tmp_size = attrParamToExp varsize !ppc_file in
      (varname, ((translate_arg typ false),
          tmp_size, tmp_size, tmp_size))::(scoop_process_args typ rest)
    (* TODO support optional sizes example int_a would have size of sizeof(int_a) *)
(*    | (ACons(varname, [])::rest) ->
      let tmp_size = SizeOfE (Lval (var (find_scoped_var !currentFunction !ppc_file varname))) in
      (varname, ((translate_arg typ false),
          tmp_size, tmp_size, tmp_size))::(scoop_process_args typ rest)*)
(*         | handle strided... *)
    | [] -> []
    | _ -> ignore(E.log "Syntax error in #pragma css task %s(...)\n" typ); []

let rec scoop_process = function
  | (AStr("highpriority")::rest) -> scoop_process rest
  | (ACons(arg_typ, args)::rest) -> (scoop_process_args arg_typ args)@(scoop_process rest)
  | [] -> []
  | _ -> ignore(E.warn "Syntax error in #pragma css task\n"); []

(* populates the global list of spu tasks [spu_tasks] *)
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
        (Attr("css", AStr("wait")::rest), loc) -> (
          (* Support #pragma css wait on(...) *)
          match rest with 
              ACons("on", exps)::_ -> (* wait on *) DoChildren
            | AStr("all")::_ -> ( (* wait all *)
                let twa = find_function_sign (!ppc_file) "tpc_wait_all" in
                let instr = Call (None, Lval (var twa), [], locUnknown) in
                let s' = {s with pragmas = List.tl s.pragmas} in
                ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)
            )
            | _ -> ignore(E.warn "Ignoring wait pragma at %a" d_loc loc); DoChildren
        )
        | (Attr("css", ACons("start", exp::rest)::_), loc) -> (
          (* Support #pragma css start(processes) *)
          let ts = find_function_sign (!ppc_file) "tpc_init" in
          let args = 
            if (!arch="cell") then
              [attrParamToExp exp !ppc_file]
            else
              attrParamToExp exp !ppc_file::[attrParamToExp (L.hd rest) !ppc_file]
          in
          let instr = Call (None, Lval (var ts), args, locUnknown) in
          let s' = {s with pragmas = List.tl s.pragmas} in
          ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)
        )
        | (Attr("css", AStr("finish")::rest), loc) -> (
          (* Support #pragma css finish*)
          let ts = find_function_sign (!ppc_file) "tpc_shutdown" in
          let instr = Call (None, Lval (var ts), [], locUnknown) in
          let s' = {s with pragmas = List.tl s.pragmas} in
          ChangeDoChildrenPost ((mkStmt (Block (mkBlock [ mkStmtOneInstr instr; s' ]))), fun x -> x)
        )
        | _ -> ();
      match s.skind with 
        Instr(Call(_, Lval((Var(vi), _)), oargs, _)::_) -> (
          (* select the function to create the custom tpc_calls *)
          let make_tpc_funcf = match !arch with
              "cell" -> Scoop_cell.make_tpc_func
            | "cellgod" -> Scoop_cellgod.make_tpc_func
            | _ ->  Scoop_x86.make_tpc_func in

          match (List.hd prags) with 
            (Attr("tpc", args), _) -> (
              let funname = vi.vname in
              let args' =
                List.map (fun arg -> match arg with
(*                     ACons(varname, ACons(arg_typ, [])::ACons(varsize, [])::[]) -> *)
                    ACons(varname, ACons(arg_typ, [])::varsize::[]) ->
                      (varname, ((translate_arg arg_typ false),
                          attrParamToExp varsize !ppc_file,
                          attrParamToExp varsize !ppc_file,
                          attrParamToExp varsize !ppc_file))
(*                   | ACons(varname, ACons(arg_typ, [])::ACons(varsize, [])::ACons(elsize, [])::ACons(elnum, [])::[]) -> *)
                  | ACons(varname, ACons(arg_typ, [])::varsize::elsize::elnum::[]) ->
                      (varname, ((translate_arg arg_typ true),
                        attrParamToExp varsize !ppc_file,
                        attrParamToExp elsize !ppc_file,
                        attrParamToExp elnum !ppc_file))
                  | _ -> ignore(E.error "impossible"); assert false
                ) args in
              ignore(E.log "Found task \"%s\"\n" funname);
              let rest new_fd = 
                (* push arguments to the call *)
                let call_args = ref [] in
                let args_num = (List.length args')-1 in
                for i = 0 to args_num do
                  let (vname, (_, _, _, _)) = List.nth args' i in
                  call_args := Lval(var (find_scoped_var !currentFunction !ppc_file vname))::!call_args;
                done;
                for i = 0 to args_num do
                  let (_, (arg_type, vsize, velsz, vels)) = List.nth args' i in
(*                   call_args := Lval(var (find_scoped_var !currentFunction !ppc_file vsize))::!call_args; *)
                  call_args := vsize::!call_args;
                  if (is_strided arg_type) then
(*                    call_args := Lval(var (find_scoped_var !currentFunction !ppc_file vels))::
                      Lval(var (find_scoped_var !currentFunction !ppc_file velsz))::!call_args;*)
                    call_args := vels::velsz::!call_args;
                done;
                let instr = Call (None, Lval (var new_fd.svar), L.rev !call_args, locUnknown) in
                let call = mkStmtOneInstr instr in
                ChangeTo(call) in
              try
                (* check if we have seen this function before *)
                let (new_fd, _, fargs) = List.assoc funname !spu_tasks in
                rest new_fd
              with Not_found -> (
                let rest2 var_i = 
                  let (new_fd, args) = make_tpc_funcf var_i oargs args' ppc_file spu_file in
                  add_after_s !ppc_file var_i.vname new_fd;
                  spu_tasks := (funname, (new_fd, var_i, args))::!spu_tasks;
                  rest new_fd in
                (* try to find the function definition *)
                try
                  (* checking for the function definition *)
                  let task = find_function_fundec (!ppc_file) funname in
                  (* copy itself and the callees *)
                  deep_copy_function funname callgraph !spu_file !ppc_file;
                  rest2 task.svar
                (* else try to find the function signature/prototype *)
                with Not_found -> (
                  let task = find_function_sign (!ppc_file) funname in
                  rest2 task
                )
              )
            )
            (* Support for CellSs syntax *)
            | (Attr("css", sub::rest), loc) -> (
              match sub with
                (* Support #pragma css task... *)
                AStr("task")-> (
                  match s.skind with 
                    Instr(Call(_, Lval((Var(vi), _)), oargs, _)::_) -> (
                      let funname = vi.vname in
                      let args = scoop_process rest in
                      ignore(E.log "Found task \"%s\"\n" funname);
                      let rest_f new_fd = 
                        (* add arguments to the call *)
                        let call_args = ref (L.rev oargs) in
(*                         let args_num = (List.length args)-1 in *)
                        
                        (* push call args from the start...
                        for i = 0 to args_num do
                          let (vname, _, _, _, _) = List.nth args i in
                          call_args := Lval(var (find_scoped_var !currentFunction !ppc_file vname))::!call_args;
                        done;*)

                        (* for each actual argument of the call find it's (pragma)
                           declared size and push it to the argument list of them
                           new call *)
                        let rec getSize ex = match ex with
                          Lval ((Var(vi),_))
                          | StartOf ((Var(vi),_)) -> (
                            try
                              let (arg_type, vsize, velsz, vels) = L.assoc vi.vname args in
                              call_args := vsize::!call_args;
                            with Not_found ->
                              ignore(E.error "You probably forgot to add \"%s\" in the pragma directive\n" vi.vname);
                              assert false
                          )
                          | CastE (_, ex') -> getSize ex';
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
                        L.iter getSize oargs;

(*                        for i = 0 to args_num do
                          let (_, arg_type, vsize, velsz, vels) = List.nth args i in
(*                           call_args := Lval(var (find_scoped_var !currentFunction !ppc_file vsize))::!call_args; *)
                          call_args := vsize::!call_args;
                          if (is_strided arg_type) then
                            (*call_args := Lval(var (find_scoped_var !currentFunction !ppc_file vels))::
                              Lval(var (find_scoped_var !currentFunction !ppc_file velsz))::!call_args;*)
                            call_args := vels::velsz::!call_args;
                        done;*)
                        let instr = Call (None, Lval (var new_fd.svar), L.rev !call_args, locUnknown) in
                        let call = mkStmtOneInstr instr in
                        ChangeTo(call) in
                      try
                        (* check if we have seen this function before *)
                        let (new_fd, _, _) = List.assoc funname !spu_tasks in
                        rest_f new_fd
                      with Not_found -> (
                        let rest_f2 var_i = 
                          let (new_fd, args) = make_tpc_funcf var_i oargs args ppc_file spu_file in
                          add_after_s !ppc_file var_i.vname new_fd;
                          spu_tasks := (funname, (new_fd, var_i, args))::!spu_tasks;
                          rest_f new_fd in
                        (* try to find the function definition *)
                        try
                          (* checking for the function definition *)
                          let task = find_function_fundec (!ppc_file) funname in
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
                    | Block(b) -> ignore(E.warn "Ignoring block pragma at %a" d_loc loc); DoChildren
                    | _ -> ignore(E.warn "Ignoring pragma at %a" d_loc loc); DoChildren
                )
                | _ -> ignore(E.warn "Unrecognized pragma"); DoChildren
            )
            | _ -> ignore(E.warn "Unrecognized pragma"); DoChildren
        )
        | Block(b) -> ignore(E.unimp "Ignoring block pragma"); DoChildren
        | _ -> ignore(E.warn "Ignoring pragma"); DoChildren
    ) else 
      DoChildren
end

let feature : featureDescr = 
  { fd_name = "findspucode";
    fd_enabled = ref true;
    fd_description = "find all pragmas declaring spu tasks";
    fd_extraopt = options
    @ Ptatype.options
    @ Uniqueness.options
    @ Locksettings.options
    (*@ Livevars.options*)
    @ Shared.options
    @ Correlation.options
    @ Controlflow.options
    @ Bansheemlifc.options
    @ Labelflow.options
    @ Lprof.options
    @ Ptdepa.options
    ;
    fd_doit = 
    (function (f: file) ->
      if !dotrace then Trace.traceAddSys "scoop";
      if !debug then ignore(E.log "Welcome to SCOOP!!!\n");
      if (!arch = "unknown") then
        ignore(E.error "Specify an architecture using --runtime=<arch>, where <arch> is one of cell/cellgod/x86.\n");
      if (!arch = "cell" && !queue_size = "0") then
        ignore(E.error "Specify the queue_size used when compiling the TPC/ADAM libraries using --queue_size=<size>.\n");

      spu_file := { dummyFile with fileName = (!out_name^"_func.c");};
      ppc_file := { f with fileName = (!out_name^".c");};

      let callgraph = CG.computeGraph f in
      let fspuVisitor = new findSPUDeclVisitor callgraph in
    
      let def =
        (!cflags) ^ (if !stats then " -DSTATISTICS=1" else "")
      in
      let header = (!tpc_include_path)^"/scoop/tpc_scoop.h" in
      match !arch with
        "x86" ->
          preprocessAndMergeWithHeader "gcc" !ppc_file (def ^ " -DX86tpc=1 " ^ header);
      | "cellgod" ->
          preprocessAndMergeWithHeader "ppu32-gcc" !ppc_file (def ^ " -DADAM=1 -DPPU=1" ^ header);
          let new_types_l = List.filter is_typedef (!ppc_file).globals in
          (!spu_file).globals <- new_types_l;
          preprocessAndMergeWithHeader "ppu32-gcc" !spu_file (def ^ " -DADAM=1 -DSPU=1" ^ header);
      | "cell"  ->
          preprocessAndMergeWithHeader "ppu32-gcc" !ppc_file (def ^ " -DMAX_QUEUE_ENTRIES=" ^ (!queue_size) ^ " -DPPU=1" ^ header);
          let new_types_l = List.filter is_typedef (!ppc_file).globals in
          (!spu_file).globals <- new_types_l;
          preprocessAndMergeWithHeader "ppu32-gcc" !spu_file (def ^ " -DMAX_QUEUE_ENTRIES=" ^ (!queue_size) ^ " -DSPU=1" ^ header);
      | _ -> ignore(E.error "architecture not supported");

      Cil.iterGlobals !ppc_file 
        (function
          GFun(fd,_) ->
            currentFunction := fd;
            ignore(visitCilFunction fspuVisitor fd);
        | _ -> ()
        );

      (* kasas was here :P *)
      if (!arch = "cellgod") then
        (Ptdepa.find_dependencies f);

      (* copy all globals except the function declaration of "tpc_call_tpcAD65" *)
      (!ppc_file).globals <- List.filter isNotSkeleton (!ppc_file).globals;

      (* tasks  (new_tpc * old_original * args) *)
      let tasks : (fundec * varinfo * (int * arg_descr) list) list = List.map
        (fun (name, (new_fd, old_fd, args)) -> (new_fd, old_fd, args))
        (L.rev !spu_tasks)
      in
      if (!arch = "cell") then (
        (!spu_file).globals <- (!spu_file).globals@[(make_exec_func !spu_file tasks)];
      ) else (
        (!ppc_file).globals <- (make_null_task_table tasks)::(!ppc_file).globals;
        (!spu_file).globals <- (!spu_file).globals@[(make_task_table tasks)];
      );

        writeFile !ppc_file;
        writeFile !spu_file;
    );
    fd_post_check = true;
  }
