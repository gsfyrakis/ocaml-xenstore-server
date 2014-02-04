

external map_foreign: int -> nativeint -> Io_page.t = "stub_map_foreign"
external unmap_foreign: Io_page.t -> unit           = "stub_unmap_foreign"

let map_fd fd len = Bigarray.Array1.map_file fd Bigarray.char Bigarray.c_layout true len

type domain = {
  domid: int;
  dying: bool;
  shutdown: bool;
}

external stub_sizeof_domaininfo_t: unit -> int                    = "stub_sizeof_domaininfo_t"
external stub_domain_getinfolist:  int -> int -> Cstruct.t -> int = "stub_domain_getinfolist"
external stub_domaininfo_t_parse:  Cstruct.t -> domain            = "stub_domaininfo_t_parse"

open Lwt

let batch_size = 512 (* number of domains to query in one hypercall *)

let sizeof = stub_sizeof_domaininfo_t ()
let getdomaininfo_buf = Cstruct.of_bigarray (Io_page.get (batch_size * sizeof))

let domain_getinfolist lowest_domid =
  let number_found = stub_domain_getinfolist lowest_domid batch_size getdomaininfo_buf in
  let rec parse buf n acc =
    if n = number_found
    then acc
    else parse (Cstruct.shift buf sizeof) (n + 1) (stub_domaininfo_t_parse buf :: acc) in
  parse getdomaininfo_buf 0 []

let list () =
  let rec loop from =
    let first = domain_getinfolist from in
    (* If we returned less than a batch then there are no more. *)
    if List.length first < batch_size
    then first
    else match first with
    | [] -> []
    | x :: xs ->
      (* Don't assume the last entry has the highest domid *)
      let largest_domid = List.fold_left (fun domid di -> max domid di.domid) x.domid xs in
      let rest = loop (largest_domid + 1) in
      first @ rest in
  loop 0
