open Lwt
open Sexplib
open Xenstore
open Persistence


let debug fmt = Logging.debug "effects" fmt
let info  fmt = Logging.info  "effects" fmt
let error fmt = Logging.error "effects" fmt

type t = unit

let nothing = ()

exception Not_implemented of string

let (>>|=) m f = m >>= function
  | `Ok x -> f x
  | `Enoent _
  | `Not_implemented _ as e -> return e

module Make(V: VIEW) = struct

  (* Every write or mkdir will recursively create parent nodes if they
     don't already exist. *)
  let rec mkdir v path node =
    V.mem v path >>= function
    | true ->
      return (`Ok ())
    | false ->
      let dirname = Protocol.Path.dirname path in
      ( if dirname <> Protocol.Path.empty
        then mkdir v dirname node
        else return (`Ok ()) ) >>|= fun () ->
      V.write v path node >>|= fun () ->
      return (`Ok ())

  let empty_node () =
    Node.({ creator = 0;
            perms = Protocol.ACL.({ owner = 0; other = NONE; acl = []});
            value = "" })

  let transactions = Hashtbl.create 16

  let with_transaction hdr f =
    if hdr.Protocol.Header.tid = 0l then begin
      (* XXX: this shouldn't be allowed to generate conflicts *)
      V.create () >>= fun v ->
      f v >>|= fun (response, side_effects) ->
      V.merge v "with_transaction" >>= fun () ->
      return (`Ok (response, side_effects))
    end else begin
      let v = Hashtbl.find transactions hdr.Protocol.Header.tid in
      f v
    end

  (* The 'path operations' are the ones which can be done in transactions.
     The other operations are always done outside any current transaction. *)
  let pathop path op v = match op with
  | Protocol.Request.Read ->
    V.read v path >>|= fun node ->
    return (`Ok (Protocol.Response.Read node.Node.value, nothing))
  | Protocol.Request.Getperms ->
    V.read v path >>|= fun node ->
    return (`Ok (Protocol.Response.Getperms node.Node.perms, nothing))
  | Protocol.Request.Setperms perms ->
    V.read v path >>|= fun node ->
    V.write v path { node with Node.perms } >>|= fun () ->
    return (`Ok (Protocol.Response.Setperms, nothing))
  | Protocol.Request.Directory ->
    V.list v path >>|= fun names ->
    return (`Ok (Protocol.Response.Directory names, nothing))
  | Protocol.Request.Write value ->
    let node = Node.({ creator = 0;
                       perms = Protocol.ACL.({ owner = 0; other = NONE; acl = []});
                       value }) in
    mkdir v (Protocol.Path.dirname path) (empty_node ()) >>|= fun () ->
    V.write v path node >>|= fun () ->
    return (`Ok (Protocol.Response.Write, nothing))
  | Protocol.Request.Mkdir ->
    mkdir v path (empty_node ()) >>|= fun () ->
    return (`Ok (Protocol.Response.Write, nothing))
  | Protocol.Request.Rm ->
    V.rm v path >>|= fun node ->
    return (`Ok (Protocol.Response.Rm, nothing))

  let reply_or_fail hdr req = match req with
  | Protocol.Request.PathOp (path, op) ->
    let path = Protocol.Path.of_string path in
    with_transaction hdr (pathop path op)
  | Protocol.Request.Getdomainpath domid ->
    return (`Ok (Protocol.Response.Getdomainpath (Printf.sprintf "/local/domain/%d" domid), nothing))
  | _ ->
    return (`Not_implemented (Protocol.Op.to_string hdr.Protocol.Header.ty))

  let reply hdr req =
    debug "<-  rid %ld tid %ld %s"
      hdr.Protocol.Header.rid hdr.Protocol.Header.tid
      (Sexp.to_string (Protocol.Request.sexp_of_t req));

    let errorwith ?(error_info = None) code =
      return ((Protocol.Response.Error code, nothing), error_info) in

    Lwt.catch
      (fun () ->
        reply_or_fail hdr req >>= function
        | `Ok x -> return (x, None)
        | `Enoent path -> errorwith ~error_info:(Some (Protocol.Path.to_string path)) "ENOENT"
        | `Not_implemented fn -> errorwith ~error_info:(Some fn) "EINVAL"
      )
      (fun e ->
        match e with
        (*
        | Transaction_again                     -> errorwith "EAGAIN"
        | Limits.Limit_reached                  -> errorwith "EQUOTA"
        | Store.Already_exists p                -> errorwith ~error_info:p "EEXIST"
        | Node.Doesnt_exist p                   -> errorwith ~error_info:(Protocol.Path.to_string p) "ENOENT"
        | Perms.Permission_denied               -> errorwith "EACCES"
        *)
        | Protocol.Path.Invalid_path(p, reason) -> errorwith ~error_info:(Some (Printf.sprintf "%s: %s" p reason)) "EINVAL"
        | Not_found                             -> errorwith "ENOENT"
        | Invalid_argument i                    -> errorwith ~error_info:(Some i) "EINVAL"
        | Not_implemented x                     -> errorwith ~error_info:(Some x) "EINVAL"
        (*
        | Limits.Data_too_big                   -> errorwith "E2BIG"
        | Limits.Transaction_opened             -> errorwith "EQUOTA" *)
        | (Failure "int_of_string")             -> errorwith ~error_info:(Some "int_of_string") "EINVAL"
        (*
        | Tree.Unsupported                      -> errorwith "ENOTSUP"
        *)
        | e ->
          (* quirk: Write <string> (no value) is one of several parse
             failures where EINVAL is expected instead of EIO *)
          errorwith ~error_info:(Some (Printexc.to_string e)) "EINVAL"
      ) >>= fun ((response_payload, side_effects), info) ->
    debug "->  rid %ld tid %ld %s%s"
      hdr.Protocol.Header.rid hdr.Protocol.Header.tid
      (Sexp.to_string (Protocol.Response.sexp_of_t response_payload))
      (match info with None -> "" | Some x -> " " ^ x);
    return (response_payload, side_effects)
end
