open Pretty
open Cil
open Printf

module PT = Ptatype
module LF = Labelflow
module E = Errormsg
module CF = Controlflow

let do_graph_out = ref false

let do_task_graph_out = ref true 

let do_verbose_output = ref true

let options = [
  "--save-graph",
  Arg.Set(do_graph_out),
  "PtDepa: Write constraints in \"graph.dot\".";

  "--save-dependencies-graph",
  Arg.Set(do_task_graph_out),
  "PtDepa: Write task dependecies in \"task-dep.dot\".";

  "--verbose-output",
  Arg.Set(do_verbose_output),
  "PtDepa: Verbose output.";
]

             (* argname * in/out type * fundec *)
type arg_type = (string * string * fundec) (* FIXME:fundec is the global one, note the function it belogs to *)
          (* (taskname * (callsiteloc * taskscope)) *) 
and task_descr = (string * (location * fundec))
          (* (task scope * taskname) * argument list *)
and task_type = (task_descr * arg_type list) 
                      (* parent task_descr  *)
and dep_node = arg_type * task_descr

and arg_dep_node = (arg_type * dep_node list)

and task_dep_node = (task_descr * arg_dep_node list)

(* each node is a task, with a list of tasks that are not depended with each other *)
let tasks_l : task_type list ref = ref []
(* temp list, used to collect task arguments *)
let args_l : arg_type list ref = ref []
(* each node is a task with its arguments, for each argument there is a list
  of depended arguments *)
let task_dep_l : task_dep_node list ref = ref []
(* dependence list with marked callsites for multiple calls to the same function *)
(* let inst_task_dep_l : task_dep_node list ref = ref [] *)

(*
(* Map calls to call site (index) for graphviz output *)
module CallMap = Map.Make(String)

let graph_calls = ref CallMap.empty

(* return last call site of given task *)
let callsite_no (taskname: string) : int =
  let callsite = begin 
    try begin
      CallMap.find taskname !graph_calls
    end  
    with Not_found -> 0
  end in
  graph_calls := CallMap.add taskname (callsite+1) !graph_calls;
  callsite
(* 
 * copies task_dep_list and adds an callsite index for 
 * every different callsite of a task
 *)
let instantiate_depList (a: unit): unit = begin
  ignore(E.log "instantiating tasks\n");
  List.iter 
    (fun tasknode -> 
      let ((scope, taskname), args) = tasknode in
      let inst_taskname = taskname^(string_of_int (callsite_no taskname)) in
      ignore(E.log "renaming %s to %s\n" taskname inst_taskname);
      inst_task_dep_l := ((scope, inst_taskname), args)::!inst_task_dep_l)
    !task_dep_l
end
*)   

(*
 * first collect all task arguments, then 
 * call addTask to add a new task with 
 * its arguments
 *)
let addTask (taskname: string) (scope: fundec) (callsite: location): unit =
  ignore(E.log "add task\n");
  tasks_l := ((taskname, (callsite, scope)), !args_l)::!tasks_l;
  args_l := []

let addArg (arg: arg_type) : unit =
  args_l := arg::!args_l

(* return true if arg_t is In or SIn *)
let is_in_arg (arg: string): bool = 
  match arg with 
      "input" -> true (* for css tags  *)
    | "in" -> true    (* for tpc legacy tags *)
    | _ -> false

(* return rhoSet for the specific arg (argument is argname * function descriptor) *)
let get_rhoSet (arg: arg_type) : LF.rhoSet =
  let (argname, _, func) = arg in
  let env = List.assoc func !PT.global_fun_envs in
  let (argtype, argaddress) = PT.env_lookup argname env in
  (* ignore(E.log "lookup of %s gives location %a with type %a\n" argname
            LF.d_rho argaddress PT.d_tau argtype); *)
  match argtype.PT.t with
  | PT.ITPtr(_, r) -> LF.close_rhoset_m (LF.RhoSet.singleton r)
  | _ ->  ignore(E.log "Warning: %s is not a pointer" argname);
	  LF.RhoSet.empty (* if arg is not a pointer, return an empty set
			   * so that is_aliased returns false *)

(* check if arg1 aliases to arg2 *)
let is_aliased (arg1: arg_type) (arg2: arg_type) : bool =
  (* if both arguments are only inputs, return false (they could 
     be aliased, but we treat them as if the were not) *)
  let (_, t, _) = arg1 in
  let (_, t', _) = arg2 in
  if((is_in_arg t) && (is_in_arg t')) then false
  else
    let set1 = get_rhoSet arg1 in
    let set2 = get_rhoSet arg2 in
    let final_set = LF.RhoSet.inter set1 set2 in
    if !do_verbose_output then begin
      let (argname1, _, _) = arg1 in
      let (argname2, _, _) = arg2 in
      ignore(E.log "%s set           : %a\n" argname1 LF.d_rhoset set1);
      ignore(E.log "%s set           : %a\n" argname2 LF.d_rhoset set2);
      ignore(E.log "rhoset intersection: %a\n" LF.d_rhoset final_set);
    end;
    not (LF.RhoSet.is_empty final_set)

(*
(* 
 * traverses a list of arguments and check if arg1 aliases 
 * with any of them.
 * returns all depended args to arg1
 *)
let rec check_args (arg1: arg_type) 
                  (args: arg_type list) 
                  (taskinf: string) 
                  (dep_args: dep_node list) : dep_node list = 
  match args with 
    [] -> dep_args
  | (arg2::tl) -> if(is_aliased arg1 arg2) then 
                    check_args arg1 tl taskinf ((arg2, taskinf)::dep_args)
                  else 
                    check_args arg1 tl taskinf dep_args

*)                  
(*
 * traverses a list of arguments (args), for each, it calls 
 * check_arg to check for any dependencies with args'.
 * return a list of arguments and for each a list of 
 * dependencies
 *)
let rec check_arg (arg: arg_type) (tasks: task_type list) : dep_node list =
  let rec check_task dep_args = function
    [] -> dep_args
  | (task::tl) -> let (taskinf', args) = task in
                  let rec check_arg' dep_args' = function
                    [] -> dep_args'
                  | (arg'::tl) -> if(is_aliased arg arg') then 
                                    check_arg' ((arg', taskinf')::dep_args') tl
                                  else 
                                    check_arg' dep_args' tl
                  in check_task (dep_args@(check_arg' [] args)) tl
  in check_task [] tasks


(* checks for any dependencies with task *)
let find_task_dependencies (task: task_type) : unit = begin
  let (taskinf, args) = task in
  let rec find_task_dependencies' arg_dep = function 
    [] -> arg_dep  
  | (arg::tl) -> find_task_dependencies' ((arg, (check_arg arg !tasks_l))::arg_dep) tl
  in    
  let task_dep = (taskinf, (find_task_dependencies' [] args)) in 
  task_dep_l := (task_dep::!task_dep_l)
end

(* prints dependencies list *)
let print_task_dependencies (task: task_dep_node) : unit = begin
  let ((taskname,(loc, _)), args) = task in
  ignore(E.log "%s.%s:%d\n" taskname loc.file loc.line); 
  List.iter 
    (fun arg ->
      let ((argname, _, _), dependencies) = arg in 
      ignore(E.log "\t%s\n" argname);
      List.iter 
        (fun dep -> 
          let ((argname, _, _), (taskname, (loc, _))) = dep in
            ignore(E.log "\tdep:%s in task:%s.%s:%d\n" argname taskname loc.file loc.line)
        ) dependencies
    ) args

end

(* 
 * Traverses the argument list and checks if the dependence list is empty,
 * in which case it return false, no dependences, or true if the list is not
 * empty.
*)
let hasDependencies (args: arg_dep_node list) (argname: string) : bool = 
  let rec hasDependencies' = function
    [] -> false
  | (arg_n::tl) -> let ((argname', _, _), deps) = arg_n in
    if(argname'=argname) then 
    begin
      match deps with
        [] -> false
      | _ -> true
    end
    else 
      hasDependencies' tl
  in hasDependencies' args

(* return true if the argument has no dependencies  *)
let isSafeArg (task: fundec) (argname: string) : bool =
  let taskname = task.svar.vname in 
  let rec search_list = function 
      [] -> false
    | (task_n::tl) -> begin
      let ((taskname', _), args) = task_n in 
      if(taskname' = taskname) then 
        not (hasDependencies args argname)
      else 
        search_list tl
    end
  in
  search_list (!task_dep_l)

let taskId (taskinf: task_descr) : string = 
  let (taskname, (loc, _)) = taskinf in
  taskname^"_"^(string_of_int loc.line);
  taskname

(* writes dependencies in graphiz format *)
let plot_task_dep_graph (outf: out_channel) : unit = begin 
  let rec plot_task edges = function
    [] -> edges
  | (task::tl) -> 
      let(taskinf, args) = task in
      let tasknode = (taskId taskinf) in
      Printf.fprintf outf "\tsubgraph cluster_%s {\n" tasknode;
      Printf.fprintf outf "\t\tlabel = \"%s\"\n" tasknode;
      Printf.fprintf outf "\t\tcolor=blue;\n";
      let rec plot_args edges = function
        [] -> Printf.fprintf outf "\t}\n";
              edges
      | (arg::tl) ->  
        let ((argname, _, _), dependencies) = arg in
	Printf.fprintf outf "\t\t%s_%s [label = \"%s\"];\n" tasknode argname argname;
	let rec plot_dependencies edges' = function
          [] -> edges'
        | (dep::tl) -> 
          let ((argname', _, _), taskinf') = dep in
          let tasknode' = (taskId taskinf') in
          let edge = ("\t\t"^tasknode^"_"^argname^" -> "^tasknode'^"_"^argname'^"\n") in
          plot_dependencies  (edges'^edge) tl	    
        in 
        plot_args (edges^(plot_dependencies "" dependencies)) tl
      in	
      plot_task (edges^(plot_args "" args)) tl
  in
  Printf.fprintf outf "%s" (plot_task "" !task_dep_l)
end

(* prints argument  *)
let print_arg (arg: arg_type) : unit = begin
  let (argname, typ, _) = arg in
  ignore(E.log "\targ:%s, type:%s\n" argname typ);
end

(* print taks and argument list  *)
let print_task (task: task_type) : unit = begin
   let ((taskname, _), args) = task in
   ignore(E.log "task:%s\n" taskname);
   List.iter print_arg args;
end

(* Static analysis for task dependencies *)
let find_dependencies (f: file) : unit = begin	
  (* List.iter print_task !tasks_l; *)
  ignore(E.log "Ptdepa: Generating and solving flow constraints\n");
  Rmtmps.removeUnusedTemps f;
  Rmalias.removeAliasAttr f;
  PT.generate_constraints f;
  (* LF.done_adding (); *)
    (*Dotpretty.init_file "graph-begin.dot" "initial constraints";*)
    (*Labelflow.print_graph !Dotpretty.outf;*)
    
    (*Semiunification.print_graph !Dotpretty.outf;*)
    (*Lockstate.print_graph !Dotpretty.outf;*)
    (*CF.print_graph !Dotpretty.outf (fun a -> true);*)
    (*Dotpretty.close_file (); *)
  ignore(E.log "Ptdepa: Checking for argument dependencies\n");
  List.iter find_task_dependencies !tasks_l;
  if !do_verbose_output then begin
    ignore(E.log "Ptdepa: Dependencies found!\n");
    List.iter print_task_dependencies !task_dep_l;
  end;
  if !do_task_graph_out then begin
    ignore(E.log "Creating dot file\n");
    (* instantiate_depList ();  
    List.iter print_task_dependencies !inst_task_dep_l; *)
    Dotpretty.init_file "task-dep.dot" "task dependencies";
    plot_task_dep_graph !Dotpretty.outf;
    Dotpretty.close_file ();
  end;
end


