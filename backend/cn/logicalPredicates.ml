module Loc = Locations
module IT = IndexTerms
module BT = BaseTypes
module AT = ArgumentTypes

open IndexTerms
open Sctypes
open BaseTypes


type definition = {
    loc : Locations.t;
    args : (Sym.t * LogicalSorts.t) list;
    (* If the predicate is supposed to get used in a quantified form,
       one of the arguments has to be the index/quantified
       variable. For now at least. *)
    qarg : int option;
    body : IndexTerms.t;
    infer_arguments : ArgumentTypes.packing_ft;
  }



let open_pred global def args =
  let su = 
    make_subst
      (List.map2 (fun (s, _) arg -> (s, arg)) def.args args) 
  in
  IT.subst su def.body






module PageAlloc = struct

  module Aux(SD : sig val struct_decls : Memory.struct_decls end) = struct
    open SD

    let pPAGE_SHIFT = 12
    let pPAGE_SIZE = Z.pow (Z.of_int 2) pPAGE_SHIFT
    let mMAX_ORDER = 11
    let hHYP_NO_ORDER = -1

    let list_head_tag, _ = Memory.find_tag struct_decls "list_head"
    let hyp_pool_tag, _ = Memory.find_tag struct_decls "hyp_pool"
    let hyp_page_tag, _ = Memory.find_tag struct_decls "hyp_page"

    let (%.) t member = IT.(%.) struct_decls t (Id.id member)

    let hyp_page_size = int_ (Memory.size_of_struct hyp_page_tag)

    let vmemmap_offset_of_pointer ~vmemmap_pointer pointer = 
      pointerToIntegerCast_ pointer %-
        pointerToIntegerCast_ vmemmap_pointer

    let vmemmap_good_pointer ~vmemmap_pointer pointer range_start range_end = 
      let offset = vmemmap_offset_of_pointer ~vmemmap_pointer pointer in
      let index = offset %/ hyp_page_size in
      let phys = index %* (z_ pPAGE_SIZE) in
      and_ [ lePointer_ (vmemmap_pointer, pointer);
             eq_ (rem_ (offset, hyp_page_size), int_ 0);
             range_start %<= phys; phys %< range_end; ]

    let vmemmap_resource ~vmemmap_pointer ~vmemmap ~range_start ~range_end permission =
      let p_s, p = IT.fresh_named Loc "p" in
      let point_permission = 
        let condition = 
          vmemmap_good_pointer ~vmemmap_pointer p
            range_start range_end
        in
        and_ [condition; permission]
      in
      Resources.RE.QPredicate {
          qpointer = p_s;
          name = "Vmemmap_page";
          iargs = [];
          oargs = [get_ vmemmap p];
          permission = point_permission;
        }


  end


  let predicates struct_decls = 

    let module Aux = Aux(struct let struct_decls = struct_decls end) in
    let open Aux in


    let vmemmap_page_wf =

      let id = "Vmemmap_page_wf" in
      let loc = Loc.other "internal (Vmemmap_page_wf)" in

      let page_pointer_s, page_pointer = IT.fresh_named Loc "page_pointer" in
      let vmemmap_pointer_s, vmemmap_pointer = IT.fresh_named Loc "vmemmap_pointer" in
      let pool_pointer_s, pool_pointer = IT.fresh_named Loc "pool_pointer" in
      let pool_s, pool = IT.fresh_named (BT.Struct hyp_pool_tag) "pool" in

      let vmemmap_s, vmemmap = 
        IT.fresh_named (BT.Array (Loc, BT.Struct hyp_page_tag)) "vmemmap" 
      in

      (* let page_s, page = IT.fresh_named (Struct hyp_page_tag) "page" in *)
      let page = get_ vmemmap page_pointer in


      let args = [
          (page_pointer_s, IT.bt page_pointer);
          (* (page_s, IT.bt page); *)
          (vmemmap_pointer_s, IT.bt vmemmap_pointer);
          (vmemmap_s, IT.bt vmemmap);
          (pool_pointer_s, IT.bt pool_pointer);
          (pool_s, IT.bt pool);
        ]
      in
      let qarg = Some 0 in

      let self_node_pointer = 
        memberShift_ (page_pointer, hyp_page_tag, Id.id "node") in

      let pool_free_area_pointer = 
        arrayShift_
          (memberShift_ (pool_pointer, hyp_pool_tag, Id.id "free_area"),
           struct_ct list_head_tag,
           page %. "order");
      in

      (* wrong, have to fix *)
      let prev_next_well_formed prev_next = 
        let prev_next = (page %. "node") %.prev_next in
        or_ [
            (* either empty list (pointer to itself) *)
            prev_next %== self_node_pointer;
            (* or pointer to free_area cell *)
            prev_next %== pool_free_area_pointer;
            (* or pointer to other vmemmap cell, within the same range*)
            vmemmap_good_pointer ~vmemmap_pointer 
              (container_of_ (prev_next, hyp_page_tag, Id.id "node"))
              (pool %. "range_start") (pool %. "range_end")
          ]
      in

      let constrs = [
          (* refcount is also valid signed int: for hyp_page_count *)
          representable_ (integer_ct (Signed Int_), page %. "refcount");
          (* order is HYP_NO_ORDER or between 0 and max_order *)
          (or_ [(page %. "order") %== int_ hHYP_NO_ORDER; 
                and_ [int_ 0 %<= (page %. "order"); (page %. "order") %< (pool %. "max_order")]]);              
          (* points back to the pool *)
          ((page %. "pool") %== pool_pointer);
          (* list emptiness via next and prev is equivalent ("prev/next" points back at node for index i_t) *)
          eq_ (((page %. "node") %. "next") %== self_node_pointer,
               ((page %. "node") %. "prev") %== self_node_pointer);
          (* list non-empty in the above sense if and only if refcount 0 and order != NYP_NO_ORDER *)
          (eq_ (
               ((page %. "node") %. "next") %!= self_node_pointer,
               and_ [(page %. "refcount") %== int_ 0;
                     (page %. "order") %!= int_ hHYP_NO_ORDER;
                 ]
          ));
          prev_next_well_formed "prev";
          prev_next_well_formed "next";
        ]
      in


      let body = and_ constrs in

      let infer_arguments = 
        AT.Computational ((page_pointer_s, IT.bt page_pointer), (loc, None),
        AT.Computational ((vmemmap_pointer_s, IT.bt vmemmap_pointer), (loc, None), 
        AT.Logical ((vmemmap_s, IT.bt vmemmap), (loc, None), 
        AT.Computational ((pool_pointer_s, IT.bt pool_pointer), (loc, None),
        AT.Computational ((pool_s, IT.bt pool), (loc, None),
        AT.Resource ((Aux.vmemmap_resource ~vmemmap_pointer ~vmemmap 
                        ~range_start:(pool %. "range_start")
                        ~range_end:(pool %. "range_end") 
                        (bool_ true)), (loc, None),
        AT.I OutputDef.[
            {loc; name = "page_pointer"; value = page_pointer};
            {loc; name = "vmemmap_pointer"; value = vmemmap_pointer};
            {loc; name = "vmemmap"; value = vmemmap};
            {loc; name = "pool_pointer"; value = pool_pointer};
            {loc; name = "pool"; value = pool};
          ]))))))
      in

      (id, {loc; args; body; qarg; infer_arguments} )
    in




    (* check: possibly inconsistent *)
    let free_area_cell_wf =

      let id = "FreeArea_cell_wf" in
      let loc = Loc.other "internal (FreeArea_cell_wf)" in

      let cell_index_s, cell_index = IT.fresh_named Integer "cell_index" in
      let cell_s, cell = IT.fresh_named (BT.Struct list_head_tag) "cell" in
      let vmemmap_pointer_s, vmemmap_pointer = IT.fresh_named Loc "vmemmap_pointer" in
      let vmemmap_s, vmemmap = 
        IT.fresh_named (BT.Array (Loc, BT.Struct hyp_page_tag)) "vmemmap" in
      let pool_pointer_s, pool_pointer = IT.fresh_named Loc "pool_pointer" in
      let range_start_s, range_start = IT.fresh_named Integer "range_start" in
      let range_end_s, range_end = IT.fresh_named Integer "range_end" in

      let args = [
          (cell_index_s, IT.bt cell_index);
          (cell_s, IT.bt cell);
          (vmemmap_pointer_s, IT.bt vmemmap_pointer);
          (vmemmap_s, IT.bt vmemmap);
          (pool_pointer_s, IT.bt pool_pointer);
          (range_start_s, IT.bt range_start);
          (range_end_s, IT.bt range_end);
        ]
      in
      let qarg = Some 0 in

      let order = cell_index in

      let free_area_pointer = 
        memberShift_ (pool_pointer, hyp_pool_tag, Id.id "free_area") in


      let cell_pointer = arrayShift_ (free_area_pointer, struct_ct list_head_tag, cell_index) in

      
      
      (* let index_in_free_area = 
       *   offset_within_free_area %/ (int_ (Memory.size_of_struct list_head_tag))
       * in
       * 
       * let order = index_in_free_area in *)


      let body = 
        let prev = cell %. "prev" in
        let next = cell %. "next" in
        and_ [
            (prev %== cell_pointer) %== (next %== cell_pointer);
            or_ [prev %== cell_pointer;
                 and_ begin
                     let prev_vmemmap = container_of_ (prev, hyp_page_tag, Id.id "node") in
                     let next_vmemmap = container_of_ (next, hyp_page_tag, Id.id "node") in
                     [(*prev*)
                       vmemmap_good_pointer ~vmemmap_pointer prev_vmemmap range_start range_end;
                       ((get_ vmemmap prev_vmemmap) %. "order") %== order;
                       ((get_ vmemmap prev_vmemmap) %. "refcount") %== (int_ 0);
                       (((get_ vmemmap prev_vmemmap) %. "node") %. "next") %== cell_pointer;
                       (*next*)
                       vmemmap_good_pointer ~vmemmap_pointer next_vmemmap range_start range_end;
                       ((get_ vmemmap next_vmemmap) %. "order") %== order;
                       ((get_ vmemmap next_vmemmap) %. "refcount") %== (int_ 0);
                       (((get_ vmemmap next_vmemmap) %. "node") %. "prev") %== cell_pointer;
                     ]
                   end
              ];
          ]
      in

      let infer_arguments =
        AT.Computational ((cell_index_s, IT.bt cell_index), (loc, None),
        AT.Computational ((cell_s, IT.bt cell), (loc, None), 
        AT.Computational ((vmemmap_pointer_s, IT.bt vmemmap_pointer), (loc, None), 
        AT.Logical ((vmemmap_s, IT.bt vmemmap), (loc, None), 
        AT.Computational ((pool_pointer_s, IT.bt pool_pointer), (loc, None),
        AT.Computational ((range_start_s, IT.bt range_start), (loc, None),
        AT.Computational ((range_end_s, IT.bt range_end), (loc, None), 
        AT.Resource ((Aux.vmemmap_resource ~vmemmap_pointer ~vmemmap ~range_start ~range_end (bool_ true)), (loc, None),
        AT.I OutputDef.[
            {loc; name = "cell_index"; value = cell_index};
            {loc; name = "cell"; value = cell};
            {loc; name = "vmemmap_pointer"; value = vmemmap_pointer};
            {loc; name = "vmemmap"; value = vmemmap};
            {loc; name = "pool_pointer"; value = pool_pointer};
            {loc; name = "range_start"; value = range_start};
            {loc; name = "range_end"; value = range_end};
          ]))))))))
      in



      (id, {loc; args; body; qarg; infer_arguments} )
    in




    (* let vmemmap_cell_address hyp_vmemmap_t i_t =
     *   arrayShift_ (hyp_vmemmap_t, 
     *                Sctype ([], Struct hyp_page_tag), 
     *                i_t)
     * in *)

    (* let _vmemmap_cell_node_address hyp_vmemmap_t i_t =
     *   memberShift_ (vmemmap_cell_address hyp_vmemmap_t i_t,
     *                 hyp_page_tag,
     *                 Id.id "node")
     * in *)




    (* let _vmemmap_node_pointer_to_index hyp_vmemmap_t pointer = 
     *   vmemmap_offset_of_node_pointer hyp_vmemmap_t pointer %/
     *     int_ (Memory.size_of_struct hyp_page_tag)
     * in *)

    (* let _vmemmap_node_pointer_to_cell_pointer hyp_vmemmap_t pointer = 
     *   vmemmap_offset_of_node_pointer hyp_vmemmap_t pointer
     * in *)




    let hyp_pool_wf =
      let id = "Hyp_pool_wf" in
      let loc = Loc.other "internal (Hyp_pool_wf)" in
      let pool_pointer_s, pool_pointer = IT.fresh_named Loc "pool_pointer" in
      let pool_s, pool = IT.fresh_named (Struct hyp_pool_tag) "pool" in
      let vmemmap_pointer_s, vmemmap_pointer = IT.fresh_named Loc "vmemmap_pointer" in
      let hyp_physvirt_offset_s, hyp_physvirt_offset = 
        IT.fresh_named BT.Integer "hyp_physvirt_offset" in

      let args = [
          (pool_pointer_s, IT.bt pool_pointer);
          (pool_s, IT.bt pool);
          (vmemmap_pointer_s, IT.bt vmemmap_pointer);
          (hyp_physvirt_offset_s, IT.bt hyp_physvirt_offset);
        ]
      in
      let qarg = None in

      let range_start = pool %. "range_start" in
      let range_end = pool %. "range_end" in
      let max_order = pool %. "max_order" in

      let beyond_range_end_cell_pointer = 
        integerToPointerCast_
          (add_ (pointerToIntegerCast_ vmemmap_pointer, 
                 (range_end %/ (z_ pPAGE_SIZE)) %* hyp_page_size))
           in
      let metadata_well_formedness =
        and_ [
            good_ (pointer_ct void_ct, integerToPointerCast_ range_start);
            good_ (pointer_ct void_ct, integerToPointerCast_ range_end);
            good_ (pointer_ct void_ct, integerToPointerCast_ (range_start %- hyp_physvirt_offset));
            good_ (pointer_ct void_ct, integerToPointerCast_ (range_end %- hyp_physvirt_offset));
            range_start %< range_end;
            rem_ (range_start, (z_ pPAGE_SIZE)) %== int_ 0;
            rem_ (range_end, (z_ pPAGE_SIZE)) %== int_ 0;
            (* for hyp_page_to_phys conversion *)
            representable_ (integer_ct Ptrdiff_t, range_end);
            good_ (pointer_ct void_ct, beyond_range_end_cell_pointer);
            max_order %>= int_ 0;
            max_order %<= int_ mMAX_ORDER;
          ]
      in
      let vmemmap_pointer_aligned = 
        aligned_ (vmemmap_pointer,
                  array_ct (struct_ct hyp_page_tag) None)
      in

      let body = and_ [metadata_well_formedness; vmemmap_pointer_aligned] in

      let infer_arguments = 
        AT.Computational ((pool_pointer_s, IT.bt pool_pointer), (loc, None),
        AT.Computational ((pool_s, IT.bt pool), (loc, None),
        AT.Computational ((vmemmap_pointer_s, IT.bt vmemmap_pointer), (loc, None), 
        AT.Computational ((hyp_physvirt_offset_s, IT.bt hyp_physvirt_offset), (loc, None), 
        AT.I OutputDef.[
            {loc; name = "pool_pointer"; value = pool_pointer};
            {loc; name = "pool"; value = pool};
            {loc; name = "vmemmap_pointer"; value = vmemmap_pointer};
            {loc; name = "hyp_physvirt_offset"; value = hyp_physvirt_offset};
          ]))))
      in

      (id, { loc; args; qarg; body; infer_arguments})
      
    in
    [vmemmap_page_wf;
     free_area_cell_wf;
     hyp_pool_wf]








      (* let vmemmap_metadata_owned =
       *   let p_s, p = IT.fresh_named Loc "p" in
       *   let point_permission = 
       *     let condition = 
       *       vmemmap_good_pointer ~vmemmap_pointer p
       *         range_start range_end
       *     in
       *     ite_ (condition, permission, q_ (0, 1))
       *   in
       *   let vmemmap_array = 
       *     QPredicate {
       *         qpointer = p_s;
       *         name = "Vmemmap_page";
       *         iargs = [
       *             vmemmap_pointer;
       *             pool_pointer;
       *             range_start;
       *             range_end;
       *           ];
       *         oargs = [get_ vmemmap p];
       *         permission = point_permission;
       *       }
       *   in
       *   let aligned = 
       *     aligned_ (vmemmap_pointer,
       *               array_ct (struct_ct hyp_page_tag) None)
       *   in
       *   LRT.Logical ((vmemmap_s, IT.bt vmemmap), (loc, None),
       *   LRT.Resource (vmemmap_array, (loc, None), 
       *   LRT.Constraint (t_ aligned, (loc, None), 
       *   LRT.I)))
       * in *)



      (* let vmemmap_well_formedness2 = 
       *   let constr prev_next =
       *     (\* let i_s, i_t = IT.fresh_named Integer "i" in *\)
       *     (\* let trigger = 
       *      *   T_Member (T_Member (T_App (T_Term vmemmap_t, T_Term i_t), Id.id "node"), Id.id prev_next)
       *      * in *\)
       *     T (bool_ true)
       *     (\* forall_trigger_ (i_s, IT.bt i_t) (Some trigger)
       *      *   begin
       *      *     let prev_next_t = ((vmemmap_t %@ i_t) %. "node") %.prev_next in
       *      *     impl_ (
       *      *         vmemmap_good_node_pointer vmemmap_pointer_t prev_next_t
       *      *       ,
       *      *         let j_t = vmemmap_node_pointer_to_index vmemmap_pointer_t prev_next_t in
       *      *         and_
       *      *           [
       *      *             (\\* (((vmemmap_t %@ j_t) %. "node") %.(if prev_next = "next" then "prev" else "next")) %== 
       *      *              *   (vmemmap_cell_node_address vmemmap_pointer_t i_t); *\\)
       *      *             ((vmemmap_t %@ i_t) %. "order") %== ((vmemmap_t %@ j_t) %. "order");
       *      *         (\\* forall_sth_ (k_s, IT.bt k_t)
       *      *          *   (and_ [(i_t %+ int_ 1) %<= k_t; 
       *      *          *          k_t %< (i_t %+ (exp_ (int_ 2, (vmemmap_t %@ i_t) %. "order")))])
       *      *          *   (and_ [
       *      *          *       ((vmemmap_t %@ k_t) %. "order") %== hHYP_NO_ORDER_t;
       *      *          *       ((vmemmap_t %@ k_t) %. "refcount") %== int_ 0;
       *      *          *     ])
       *      *          * ] *\\)
       *      *           ]
       *      *       )
       *      *   end *\)
       *   in
       *   LRT.Constraint (constr "prev", (loc, None), 
       *   LRT.Constraint (constr "next", (loc, None), 
       *   LRT.I))
       * in *)

      (* let page_group_ownership = 
       *   let qp_s, qp_t = IT.fresh_named Loc "qp" in
       *   let bytes_s, bytes_t = IT.fresh_named (BT.Array (Loc, Integer)) "bytes" in
       *   let condition = 
       *     let i_t = (pointerToIntegerCast_ qp_t) %/ pPAGE_SIZE_t in
       *     and_ [
       *         gtPointer_ (qp_t, pointer_ (Z.of_int 0));
       *           (and_ (
       *              [range_start_t %<= pointerToIntegerCast_ qp_t; 
       *               pointerToIntegerCast_ qp_t %< range_end_t;
       *               or_ [
       *                   and_ [((vmemmap_t %@ i_t) %. "order") %!= int_ hHYP_NO_ORDER;
       *                         ((vmemmap_t %@ i_t) %. "refcount") %== int_ 0];
       *                   and_ [((vmemmap_t %@ i_t) %. "order") %== int_ hHYP_NO_ORDER;
       *                         ((vmemmap_t %@ i_t) %. "refcount") %== int_ 0]
       *                 ]
       *              ]
       *           ))
       *       ]
       *   in
       *   let qpoint = 
       *     QPoint {
       *         qpointer = qp_s;
       *         size = Z.of_int 1;
       *         permission = ite_ (condition, q_ (1, 1), q_ (0, 1));
       *         value = get_ bytes_t qp_t;
       *         init = bool_ false;
       *       }
       *   in
       *   LRT.Logical ((bytes_s, IT.bt bytes_t),
       *   LRT.Resource (qpoint, LRT.I))
       * in *)


end


let predicate_list struct_decls = 
  try PageAlloc.predicates struct_decls with
  | Not_found -> []


    