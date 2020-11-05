module CF = Cerb_frontend
open TypeErrors
open Resultat
open Pp

open Resources
module BT = BaseTypes
module LC = LogicalConstraints
module RT = ReturnTypes
module IT = IndexTerms


let integer_value_to_num loc iv = 
  match CF.Impl_mem.eval_integer_value iv with
  | Some v -> return v
  | None -> fail loc (Internal !^"integer_value_to_num")

let align_of_ctype loc ct = 
  let s = CF.Impl_mem.alignof_ival ct in
  integer_value_to_num loc s

let size_of_ctype loc ct = 
  let s = CF.Impl_mem.sizeof_ival ct in
  integer_value_to_num loc s

let size_of_struct_type loc (BT.Tag s) =
  size_of_ctype loc (CF.Ctype.Ctype ([], CF.Ctype.Struct s))
  
let integer_range loc it =
  let* min = integer_value_to_num loc (CF.Impl_mem.min_ival it) in
  let* max = integer_value_to_num loc (CF.Impl_mem.max_ival it) in
  return (min,max)



open Environment

let offset loc {local; global} (BT.Tag s) (BT.Member id) = 
  let iv = CF.Impl_mem.offsetof_ival global.tagDefs s (Id.parse (Loc.unpack loc) id) in
  integer_value_to_num loc iv
