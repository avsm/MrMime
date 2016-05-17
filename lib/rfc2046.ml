open BaseLexer

let is_bcharsnospace = function
  | '\'' | '(' | ')' | '+' | '_' | ','
  | '-' | '.' | '/' | ':' | '=' | '?' -> true
  | chr -> Rfc822.is_alpha chr || Rfc822.is_digit chr

let is_bchars = function
  | ' ' -> true
  | chr -> is_bcharsnospace chr

let is_valid_bchars str =
  let i = ref 0 in

  while !i < String.length str
        && is_bchars (String.get str !i)
  do incr i done;

  !i = String.length str

let p_dash_boundary boundary p state =
  p_str "--" state;
  p_str boundary state;
  p state

let m_dash_boundary boundary =
  "--" ^ boundary

let p_transport_padding p state =
  let _ = p_repeat Rfc822.is_lwsp state in
  p state

(* See RFC 2046 § 5.1.1:

   discard-text := *( *text CRLF) *text
                   ; May be ignored or discarded.

   and RFC 822 § 3.3:

   text        =  <any CHAR, including bare    ; => atoms, specials,
                   CR & bare LF, but NOT       ;  comments and
                   including CRLF>             ;  quoted-strings are
                                               ;  NOT recognized.
*)
let p_discard_text stop p state =
  let rec text has_text state =
    let rec aux = function
      | `Stop state -> p has_text state
      | `Read (buf, off, len, k) ->
        `Read (buf, off, len, (fun i -> aux @@ safe k i))
      | #Error.err as err ->  err
      | `Continue state ->
        match cur_chr state with
        | chr -> junk_chr state; text true state
    in aux @@ safe (stop has_text) state
  in

  text false state

(* See RFC 2046 § 5.1.1:

   preamble := discard-text
   epilogue := discard-text
*)
let p_preamble = p_discard_text
let p_epilogue = p_discard_text

(* See RFC 2046 § 5.1.1:

   delimiter := CRLF dash-boundary

   XXX: need to be compose with [dash-boundary]
*)
let p_delimiter boundary p state =
  Rfc822.p_crlf (p_dash_boundary boundary p) state

let m_delimiter boundary =
  "\r\n" ^ (m_dash_boundary boundary)

let p_close_delimiter boundary p state =
  p_delimiter boundary (fun state -> p_str "--" state; p state) state

let m_close_delimiter boundary =
  (m_delimiter boundary) ^ "--"

(* See RFC 2046 § 5.1:

   body-part := MIME-part-headers [CRLF *OCTET]
                ; Lines in a body-part must not start
                ; with the specified dash-boundary and
                ; the delimiter must not appear anywhere
                ; in the body part.  Note that the
                ; semantics of a body-part differ from
                ; the semantics of a message, as
                ; described in the text.

   XXX: [p_octet] must be stop to the boundary
*)
let p_body_part (type data) boundary p_octet p state =
  let next fields state =
    p_try_rule
      (fun data -> p (Some (data : data)))
      (p None)
      (Rfc822.p_crlf @@ p_octet fields (fun data state -> `Ok ((data : data), state)))
      state
  in

  p_try_rule next
    (next [])
    (Rfc2045.p_mime_part_headers
       (fun field next state -> raise (Error.Error (Error.err_invalid_field field state)))
       (Rfc5322.p_field (fun field -> raise (Error.Error (Error.err_invalid_field field state))))
       (fun fields state -> `Ok (fields, state)))
    state

(* See RFC 2046 § 5.1.1:

   encapsulation := delimiter transport-padding
                    CRLF body-part
*)
let p_encapsulation boundary p_octet p state =
  p_delimiter boundary
    (p_transport_padding @@ Rfc822.p_crlf @@ p_body_part boundary p_octet p)
    state

(* See RFC 2046 § 5.1.1:

   multipart-body := [preamble CRLF]
                     dash-boundary transport-padding CRLF
                     body-part *encapsulation
                     close-delimiter
                     transport-padding
                     [CRLF epilogue]
*)
let p_multipart_body boundary parent_boundary p_octet p state =
  let stop_preamble has_text =
    let dash_boundary = m_dash_boundary boundary in
    p_try_rule
      (fun () state ->
       roll_back
         (fun state -> `Stop state)
         dash_boundary
         state)
      (fun state -> `Continue state)
      (p_dash_boundary boundary (fun state-> `Ok ((), state)))
  in
  let stop_epilogue state =
    match parent_boundary with
    | None ->
      p_try_rule
        (fun () -> roll_back (fun state -> `Stop state) "\r\n\r\n")
        (fun state -> `Continue state)
        (Rfc822.p_crlf @@ Rfc822.p_crlf @@ (fun state -> `Ok ((), state)))
    | Some boundary ->
      let delimiter = m_delimiter boundary in
      let close_delimiter = m_close_delimiter boundary in
      p_try_rule
        (fun () -> roll_back (fun state -> `Stop state) close_delimiter)
        (p_try_rule
           (fun () -> roll_back (fun state -> `Stop state) delimiter)
           (fun state -> `Continue state)
           (p_delimiter boundary (fun state -> `Ok ((), state))))
        (p_close_delimiter boundary (fun state -> `Ok ((), state)))
  in
  let rec next acc =
    p_try_rule
      (fun data -> next (data :: acc))
      (p_close_delimiter boundary @@ p_transport_padding
       @@ p_try_rule
            (fun () -> p (List.rev acc))
            (p (List.rev acc))
            (Rfc822.p_crlf
             @@ p_epilogue stop_epilogue (fun _ state -> `Ok ((), state))))
      (p_encapsulation boundary p_octet (fun data state -> `Ok (data, state)))
  in

  p_preamble stop_preamble
    (fun has_preamble ->
       p_dash_boundary boundary
       @@ p_transport_padding
       @@ Rfc822.p_crlf
       @@ p_body_part boundary p_octet
       @@ fun data -> next [data]) state