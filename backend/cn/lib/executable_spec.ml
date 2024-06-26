let rec group_toplevel_defs new_list = function
  | [] -> new_list
  | (loc, strs) :: xs ->
      let matching_elems = List.filter (fun (toplevel_loc, _) ->
        loc == toplevel_loc
      ) new_list in
      if List.is_empty matching_elems then
        group_toplevel_defs ((loc, strs) :: new_list) xs
      else
        (* Unsafe *)
        let (_, toplevel_strs) = List.nth matching_elems 0 in
        let non_matching_elems = List.filter (fun (toplevel_loc, _) ->
          loc != toplevel_loc
        ) new_list in
        group_toplevel_defs ((loc, toplevel_strs @ strs) :: non_matching_elems) xs

open Executable_spec_internal

let main ?(with_ownership_checking=false) filename ((_, sigm) as ail_prog) output_decorated_dir output_filename prog5 statement_locs =
  let prefix = match output_decorated_dir with | Some dir_name -> dir_name | None -> "" in
  let oc = Stdlib.open_out (prefix ^ output_filename) in
  let cn_oc = Stdlib.open_out (prefix ^ "cn.c") in
  populate_record_map prog5;
  let (instrumentation, symbol_table) = Core_to_mucore.collect_instrumentation prog5 in
  let executable_spec = generate_c_specs_internal instrumentation symbol_table statement_locs sigm prog5 in
  let (c_datatypes, c_datatype_equality_fun_decls) = generate_c_datatypes sigm in
  let (c_function_defs, c_function_decls, locs_and_c_extern_function_decls, c_records) =
  generate_c_functions_internal sigm prog5.mu_logical_predicates in
  let (c_predicate_defs, locs_and_c_predicate_decls, c_records', ownership_ctypes) =
  generate_c_predicates_internal sigm prog5.mu_resource_predicates executable_spec.ownership_ctypes in
  let (conversion_function_defs, _conversion_function_decls) =
  generate_conversion_and_equality_functions sigm in
  
  let cn_utils_header_pair = ("cn-executable/utils.h", true) in
  let cn_utils_header = Executable_spec_utils.generate_include_header cn_utils_header_pair in

  (* Ownership checking *)
  if with_ownership_checking then 
    (let ownership_oc = Stdlib.open_out (prefix ^ "ownership.c") in 
    let ownership_globals = generate_ownership_globals ~is_extern:false () in 
    Stdlib.output_string ownership_oc cn_utils_header;
    Stdlib.output_string ownership_oc "\n";
    Stdlib.output_string ownership_oc ownership_globals;
    )
  ;

  let ownership_function_defs, ownership_function_decls = generate_ownership_functions ~with_ownership_checking ownership_ctypes sigm in
  let c_structs = print_c_structs sigm.tag_definitions in
  let cn_converted_structs = generate_cn_versions_of_structs sigm.tag_definitions in

  

  (* let (records_str, record_equality_fun_strs, record_equality_fun_prot_strs) = generate_all_record_strs sigm in *)
  let (records_str, record_equality_fun_strs, record_equality_fun_prot_strs) = c_records in
  let (records_str', record_equality_fun_strs', record_equality_fun_prot_strs') = c_records' in

  let extern_ownership_globals = 
    if with_ownership_checking then 
      "\n" ^ generate_ownership_globals ~is_extern:true ()
    else "" 
  in

  (* TODO: Topological sort *)
  Stdlib.output_string cn_oc cn_utils_header;
  Stdlib.output_string cn_oc extern_ownership_globals;
  Stdlib.output_string cn_oc c_structs;
  Stdlib.output_string cn_oc cn_converted_structs;
  Stdlib.output_string cn_oc "\n/* CN RECORDS */\n\n";
  Stdlib.output_string cn_oc records_str;
  Stdlib.output_string cn_oc records_str';
  Stdlib.output_string cn_oc "\n/* CN DATATYPES */\n\n";
  Stdlib.output_string cn_oc (String.concat "\n" (List.map snd c_datatypes));
  Stdlib.output_string cn_oc record_equality_fun_strs;
  Stdlib.output_string cn_oc record_equality_fun_strs';
  Stdlib.output_string cn_oc conversion_function_defs;
  Stdlib.output_string cn_oc ownership_function_defs;
  Stdlib.output_string cn_oc c_function_decls;
  Stdlib.output_string cn_oc c_function_defs;
  Stdlib.output_string cn_oc c_predicate_defs;

  let incls = [("assert.h", true); ("stdlib.h", true); ("stdbool.h", true); ("math.h", true); cn_utils_header_pair;] in
  let headers = List.map Executable_spec_utils.generate_include_header incls in
  Stdlib.output_string oc (List.fold_left (^) "" headers);
  Stdlib.output_string oc "\n";
  Stdlib.output_string oc extern_ownership_globals;
  Stdlib.output_string oc "\n/* CN RECORDS */\n\n";
  Stdlib.output_string oc records_str;
  Stdlib.output_string oc records_str';
  Stdlib.output_string oc record_equality_fun_prot_strs;
  Stdlib.output_string oc record_equality_fun_prot_strs';
  Stdlib.output_string oc "\n\n/* OWNERSHIP FUNCTIONS */\n\n";
  Stdlib.output_string oc ownership_function_decls;
  Stdlib.output_string oc "\n";

  let struct_injs_with_filenames = Executable_spec_internal.generate_struct_injs sigm in

  let filter_injs_by_filename struct_inj_pairs fn =
    List.filter (fun (loc, _inj) -> match Cerb_location.get_filename loc with | Some name -> (String.equal name fn) | None -> false) struct_inj_pairs
  in
  let source_file_struct_injs_with_syms = filter_injs_by_filename struct_injs_with_filenames filename in
  let source_file_struct_injs = List.map (fun (loc, (_sym, strs)) -> (loc, strs)) source_file_struct_injs_with_syms in

  let included_filenames = List.map (fun (loc, _inj) -> Cerb_location.get_filename loc) struct_injs_with_filenames in
  let rec open_auxilliary_files included_filenames already_opened_list = match included_filenames with
    | [] -> []
    | fn :: fns ->
        begin match fn with
        | Some fn' ->
          if String.equal fn' filename || List.mem String.equal fn' already_opened_list then [] else
          let fn_list = String.split_on_char '/' fn' in
          let output_fn = List.nth fn_list (List.length fn_list - 1) in
          let output_fn_with_prefix = prefix ^ output_fn in
          if Sys.file_exists output_fn_with_prefix then
            (Printf.printf "Error in opening file %s as it already exists\n" output_fn_with_prefix;
            open_auxilliary_files fns (fn' :: already_opened_list))
          else
            (Printf.printf "REACHED FILENAME: %s\n" output_fn_with_prefix;
            let output_channel = Stdlib.open_out output_fn_with_prefix in
            (fn', output_channel) :: open_auxilliary_files fns (fn' :: already_opened_list))
        | None -> []
        end
  in



  let fns_and_ocs = open_auxilliary_files included_filenames [] in
  let rec inject_structs_in_header_files = function
  | [] -> ()
  | (fn', oc') :: xs ->
    let header_file_injs_with_syms = filter_injs_by_filename struct_injs_with_filenames fn' in
    let header_file_injs = List.map (fun (loc, (_sym, strs)) -> (loc, strs)) header_file_injs_with_syms in
    Stdlib.output_string oc' cn_utils_header;
    begin match
      Source_injection.(output_injections oc'
        { filename=fn'; program= ail_prog
        ; pre_post=[]
        ; in_stmt=header_file_injs}
      )
    with
    | Ok () ->
        ()
    | Error str ->
        (* TODO(Christopher/Rini): maybe lift this error to the exception monad? *)
        prerr_endline str
    end;
    Stdlib.close_out oc';
    inject_structs_in_header_files xs
  in

  let c_datatypes_with_fn_prots = List.combine c_datatypes c_datatype_equality_fun_decls in
  let c_datatypes_locs_and_strs = List.map (fun ((loc, dt_str), eq_prot_str) -> (loc, [String.concat "\n" [dt_str; eq_prot_str]])) c_datatypes_with_fn_prots in

  
  let toplevel_locs_and_defs = group_toplevel_defs [] (c_datatypes_locs_and_strs @ locs_and_c_extern_function_decls @ locs_and_c_predicate_decls) in

  let pre_post_pairs = if with_ownership_checking then 
    let global_ownership_init_pair = generate_ownership_global_assignments sigm in 
    global_ownership_init_pair @ executable_spec.pre_post
  else 
    executable_spec.pre_post
  in

  begin match
  Source_injection.(output_injections oc
    { filename; program= ail_prog
    ; pre_post=pre_post_pairs
    (* ; in_stmt=(executable_spec.in_stmt @ c_datatypes_locs_and_strs @ locs_and_c_function_decls @ locs_and_c_predicate_decls @ source_file_struct_injs)} *)
    ; in_stmt=(executable_spec.in_stmt @ source_file_struct_injs @ toplevel_locs_and_defs)}
  )
with
| Ok () ->
    ()
| Error str ->
    (* TODO(Christopher/Rini): maybe lift this error to the exception monad? *)
    prerr_endline str
end;
inject_structs_in_header_files fns_and_ocs