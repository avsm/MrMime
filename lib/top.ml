type field_message =
  [ Rfc5322.field | Rfc2045.field | Rfc2045.field_version | Rfc5322.skip ]
type field_part =
  [ Rfc5322.field | Rfc2045.field | Rfc5322.skip ]

type 'a message =
  | Discrete  of MrMime_content.t * field_message list * 'a
  | Extension of MrMime_content.t * field_message list
  | Composite of MrMime_content.t * field_message list * (MrMime_content.t * field_part list * 'a part option) list
and 'a part =
  | PDiscrete  of 'a
  | PExtension of MrMime_content.t * field_part list
  | PComposite of (MrMime_content.t * field_part list * 'a part option) list

type content = ..
type content += Base64 of MrMime_base64.result
type content += QuotedPrintable of string
type content += Raw of string

include Parser
include Parser.Convenience

type err += Expected_boundary

let message_headers =
  Rfc5322.header
    (Rfc2045.message_field
       (fun _ -> fail Rfc5322.Nothing_to_do)
       (fun _ -> fail Rfc5322.Nothing_to_do))
  >>= MrMime_header.Decoder.header
  >>= fun (header, rest) -> MrMime_content.Decoder.message rest
  >>= fun (content, rest) -> return (header, content, rest)
  (* Rfc2045.mime_message_headers
   *   (fun _ -> fail Rfc5322.Nothing_to_do) mime-extension
   *   (Rfc5322.field (fun _ -> fail Rfc5322.Nothing_to_do)) *)

let boundary content =
  try List.assoc "boundary" content.MrMime_content.ty.MrMime_contentType.parameters
      |> function `Token s | `String s -> Some s
  with Not_found -> None

let octet boundary content fields =
  let boundary, rollback = match boundary with
    | Some boundary ->
      Rfc2046.delimiter boundary,
      { f = fun i s fail succ ->
        Input.rollback i (Internal_buffer.from_string ~proof:(Input.proof i) @@  ("\r\n--" ^ boundary));
        succ i s () }
    | None -> return (), return ()
  in

  match content.MrMime_content.encoding with
  | `QuotedPrintable ->
    MrMime_quotedPrintable.decode boundary rollback
    >>| fun v -> QuotedPrintable v
  | `Base64 ->
    MrMime_base64.decode boundary rollback
    >>| fun v -> Base64 v
  | _ ->
    Rfc5322.decode boundary rollback
    >>| fun v -> Raw v

let body =
  let fix' f =
    let rec u a b c = lazy (f r a b c)
    and r a b c = { f = fun i s fail succ ->
              Lazy.(force (u a b c)).f i s fail succ }
    in r
  in

  fix' @@ fun m parent content fields ->
  match content.MrMime_content.ty.MrMime_contentType.ty with
  | #Rfc2045.extension -> return (PExtension (content, fields))
  | #Rfc2045.discrete  ->
    octet parent content fields
    >>| fun v -> PDiscrete v
  | #Rfc2045.composite ->
    match boundary content with
    | Some boundary ->
      Rfc2046.multipart_body parent boundary (m (Some boundary))
      >>| fun v -> PComposite v
    | None -> fail Expected_boundary

let message =
  message_headers
  <* Rfc822.crlf
  >>= fun (header, content, fields) -> match content.MrMime_content.ty.MrMime_contentType.ty with
  | #Rfc2045.extension -> return (header, Extension (content, fields))
  | #Rfc2045.discrete  ->
    octet None content fields
    >>| fun v -> header, Discrete (content, fields, v)
  | #Rfc2045.composite ->
    match boundary content with
    | Some boundary ->
      Rfc2046.multipart_body None boundary (body (Some boundary))
      >>| fun v -> header, Composite (content, fields, v)
    | None -> fail Expected_boundary