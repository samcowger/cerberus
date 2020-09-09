include Stdlib.List

let concat_map (f : 'a -> 'b list) (xs : 'a list) : 'b list = 
    concat (map f xs)


let rec filter_map (f : 'a -> 'b option) (xs : 'a list) : 'b list = 
  match xs with
  | [] -> []
  | x :: xs ->
     match f x with
     | None -> filter_map f xs
     | Some y -> y :: filter_map f xs


let rec equal (equality : 'a -> 'a -> bool) (xs : 'a list) (xs' : 'a list) : bool = 
  match xs, xs' with
  | [], [] -> true
  | x::xs, x'::xs' -> equality x x' && equal equality xs xs'
  | _, _ -> false
