open BaseLexer

type atom    = [ `Atom of string ]
type word    = [ atom | `String of string ]
type local   = word list
type domain  =
  [ `Literal of string
  | `Domain of atom list ]
type left   = local
type right  = domain
type msg_id = left * right

(* See RFC 822 § 3.3:

   SPACE       =  <ASCII SP, space>            ; (     40,      32. )
*)
let is_space = (=) ' '

(* See RFC 822 § 3.3:

   CTL         =  <any ASCII control           ; (  0- 37,  0.- 31.)
                   character and DEL>          ; (    177,     127.)
*)
let is_ctl = function
  | '\000' .. '\031' -> true
  | _                -> false

let is_digit = function
  | '0' .. '9' -> true
  | _          -> false

let is_lwsp = function
  | '\x20' | '\x09' -> true
  | _               -> false

(* See RFC 822 § 3.3:

   text        =  <any CHAR, including bare    ; => atoms, specials,
                   CR & bare LF, but NOT       ;  comments and
                   including CRLF>             ;  quoted-strings are
                                               ;  NOT recognized.
*)
let p_text p state =
  let buf = Buffer.create 16 in

  let rec loop has_content has_cr state =
    match cur_chr state with
    | '\n' when has_cr ->
      roll_back (p has_content (Buffer.contents buf)) "\r" state
    | '\r' ->
      if has_cr then Buffer.add_char buf '\r';
      junk_chr state;
      loop has_content true state
    | chr ->
      if has_cr then Buffer.add_char buf '\r';
      Buffer.add_char buf chr;
      junk_chr state;
      loop true false state
  in

  loop false false state

(* See RFC 822 § 3.2:

   field-name  =  1*<any CHAR, excluding CTLs, SPACE, and ":">
*)
let p_field_name state =
  p_repeat ~a:1
    (function ':' -> false | chr -> not (is_ctl chr) && not (is_space chr))
    state

(* COMMON PART BETWEEN RFC 822 AND RFC 5322 ***********************************)

(* See RFC 5234 § Appendix B.1:

   SP              = %x20
   HTAB            = %x09                 ; horizontal tab
   WSP             = SP / HTAB            ; white space

   See RFC 822 § 3.3:

   SPACE       =  <ASCII SP, space>            ; (     40,      32. )
   HTAB        =  <ASCII HT, horizontal-tab>   ; (     11,       9. )
   LWSP-char   =  SPACE / HTAB                 ; semantics = SPACE
*)
let is_wsp = function
  | '\x20' | '\x09' -> true
  | chr             -> false

let is_d0 = (=) '\000'
let is_lf = (=) '\n'
let is_cr = (=) '\r'

(* See RFC 5322 § 4.1:

   obs-NO-WS-CTL   = %d1-8 /            ; US-ASCII control
                     %d11 /             ;  characters that do not
                     %d12 /             ;  include the carriage
                     %d14-31 /          ;  return, line feed, and
                     %d127              ;  white space characters
*)
let is_obs_no_ws_ctl = function
  | '\001' .. '\008'
  | '\011'
  | '\012'
  | '\014' .. '\031'
  | '\127' -> true
  | chr    -> false

(* See RFC 5234 § Appendix B.1:

   VCHAR           = %x21-7E            ; visible (printing) characters
*)
let is_vchar = function
  | '\x21' .. '\x7e' -> true
  | chr              -> false

let of_escaped_character = function
  | 'a' -> '\x07'
  | 'b' -> '\b'
  | 't' -> '\t'
  | 'n' -> '\n'
  | 'v' -> '\x0b'
  | 'f' -> '\x0c'
  | 'r' -> '\r'
  | chr -> chr

(* See RFC 5322 § 3.2.1:

   quoted-pair     = ("\" (VCHAR / WSP)) / obs-qp)
   obs-qp          = "\" (%d0 / obs-NO-WS-CTL / LF / CR)"

   See RFC 822 § 3.3:

   quoted-pair =  "\" CHAR                     ; may quote any char"
*)
let p_quoted_pair p state =
  p_chr '\\' state;

  let chr = cur_chr state in

  if is_d0 chr
  || is_obs_no_ws_ctl chr
  || is_lf chr
  || is_cr chr
  || is_vchar chr
  || is_wsp chr
  then (junk_chr state; p (of_escaped_character chr) state)
  else raise (Error.Error (Error.err_unexpected chr state))

(* See RFC 5322 § 3.2.2:

   FWS             = ([*WSP CRLF] 1*WSP) / obs-FWS
                                          ; Folding white space
   obs-FWS         = 1*WSP *(CRLF 1*WSP)

   XXX: it's [FWS] (optionnal FWS), not FWS!, the bool argument of [p] inform
        if we are a FWS token and WSP token, or not.
        it's impossible to have [has_fws = true] and [has_wsp = false], a
        folding whitespace need at least one whitespace token.

        so for the case [has_fws = true] and [has_wsp = true], you can
        [assert false].

  See RFC 822 § 3.3:

  linear-white-space =  1*([CRLF] LWSP-char)  ; semantics = SPACE
                                              ; CRLF => folding
*)
let rec p_fws p state =
  (* verify if we have *WSP CRLF, if it's true,
     we return a [tmp] buffer containing *WSP CRLF data.

     it's not destructive, so you need to drop data with [tmp] if you try to get
     the input after the CRLF. *)
  let has_line state =
    let tmp = Buffer.create 16 in
    let rec loop cr_read j =
      Buffer.add_char tmp (Bytes.get state.Lexer.buffer j);

      if j >= state.Lexer.len then false
      else
        match Bytes.get state.Lexer.buffer j with
        | '\n' ->
          if cr_read then true else loop false (j + 1)
        | '\r' ->
          loop true (j + 1)
        | '\x20' | '\x09' -> loop false (j + 1)
        | _ -> false
    in
    if loop false state.Lexer.pos
    then Some (Buffer.contents tmp)
    else None
  in

  let trim s =
    let len = Bytes.length s in
    let i   = ref 0 in

    while !i < len && is_wsp (Bytes.get s !i)
    do incr i done;

    !i <> 0, Bytes.sub s !i (len - !i)
  in

  (* for *(CRLF 1*WSP) loop  *)
  let rec end_of_line has_wsp has_fws success fail state =
    match has_line state with
    | Some tmp ->
      state.Lexer.pos <- state.Lexer.pos + String.length tmp;

      read_line
        (fun state ->
         match cur_chr state with
         (* … 1*(CRLF 1*WSP) *)
         | '\x20' | '\x09' ->
           (* drop 1*WSP *)
           let _ = p_while is_wsp state in
           success true true state
         (* … *(CRLF 1*WSP) CRLF e *)
         | chr ->
           let has_wsp, tmp = trim tmp in
           roll_back (p has_wsp has_fws) tmp state)
        state
    (* … e *)
    | None -> fail has_wsp has_fws state
  in

  let rec loop state =
    match cur_chr state with
    (* WSP / CR *)
    | '\x20' | '\x09' | '\r' as chr ->
      let success has_wsp has_fws state =
        match chr with
        (* 1*WSP *(CRLF 1*WSP), so it's obs-fws *)
        | '\x20' | '\x09' ->
          (* it's 1*WSP 1*(CRLF 1*WSP) loop:
             we can have multiple CRLF 1*WSP because we are in obs-fws *)
          let rec loop _ _ state =
            end_of_line true true loop (fun _ _ -> p true true) state in

          loop true true state
        (* 1*(CRLF 1*WSP) *)
        | chr -> p true true state
      in
      let fail has_wsp has_fws state =
        (* WSP / CR *)
        match chr with
        | '\r' -> (* CR XXX: don't drop '\r', may be it's \r\n *)
          p has_wsp has_fws state
        | chr  -> (* we have 1*WSP, so we drop 1*WSP *)
          let _ = p_while is_wsp state in p true has_fws state
      in

      (* state (WSP / CR) and try [*WSP CRLF] 1*WSP *)
      end_of_line false false success fail state
    (* no fws *)
    | chr -> p false false state
  in

  loop state

(* See RFC 5322 § 3.2.2:

   ctext           = %d33-39 /            ; Printable US-ASCII
                     %d42-91 /            ;  characters not including
                     %d93-126 /           ;  "(", ")", or "\\"
                     obs-ctext
   obs-ctext       = obs-NO-WS-CTL

   See RFC 822 § 3.3:

   ctext       =  <any CHAR excluding "(",     ; => may be folded
                   ")", "\" & CR, & including
                   linear-white-space>"
*)
let is_ctext = function
  | '\033' .. '\039'
  | '\042' .. '\091'
  | '\093' .. '\126' -> true
  | chr -> is_obs_no_ws_ctl chr

let rec p_ctext = p_while is_ctext

(* See RFC 5322 § 3.2.2:

   ccontent        = ctext / quoted-pair / comment
   comment         = "(" *([FWS] ccontent) [FWS] ")"

   See RFC 822 § 3.3:

   comment     =  "(" *(ctext / quoted-pair / comment) ")"
*)
let rec p_ccontent p state =
  match cur_chr state with
  | '\\' -> p_quoted_pair (fun chr -> p) state
  | '(' -> p_comment p state
  | chr -> let s = p_ctext state in
    p state

and p_comment p state =
  p_chr '(' state;

  let rec loop state =
    match cur_chr state with
    | ')' ->
      junk_chr state;
      p state
    | chr ->
      (* XXX: we ignore if we passed a fws entity. *)
      p_fws (fun _ _ -> p_ccontent @@ p_fws @@ (fun _ _ -> loop)) state
  in

  loop state

(* See RFC 5322 § 3.2.2:

   CFWS            = (1*([FWS] comment) [FWS]) / FWS

   XXX: because we have only [FWS], it's [CFWS], not CFWS!
        so, we can't verify if we have really a FWS pattern, but fuck off!

   See RFC 822 § 3.4.3: LOL
*)
let p_cfws p state =
  let rec loop has_fws has_comment state =
    (* [FWS] *)
    match cur_chr state with
    (* 1*([FWS] comment) *)
    | '(' ->
      p_comment
        (p_fws (fun has_wsp' has_fws' ->
                loop (has_fws || has_wsp' || has_fws') true))
        state
      (* 1*([FWS] comment) [FWS], we ignore if we passed a fws entity. *)
    | chr ->
      match has_comment, has_fws with
      | true,  true
      | true,  false -> p true state (* comment) [FWS] *)
      | false, true  -> p true state (* / FWS *)
      | false, false -> p false state
      (* [FWS] e, we ignore if we passed a fws entity. *)
  in

  p_fws (fun has_wsp has_fws -> loop (has_wsp || has_fws) false) state

(* See RFC 5322 § 3.2.4:

   qtext           = %d33 /               ; Printable US-ASCII
                     %d35-91 /            ;  characters not including
                     %d93-126 /           ;  %x5C or the quote character
                     obs-qtext

   obs-qtext       = obs-NO-WS-CTL

   See RFC 822 § 3.3:

   qtext       =  <any CHAR excepting %d42,    ; => may be folded
                   %x5C & CR, and including
                   linear-white-space>
*)
let is_qtext = function
  | '\033'
  | '\035' .. '\091'
  | '\093' .. '\126' -> true
  | chr              -> is_obs_no_ws_ctl chr

(* See RFC 822 § 3.3:

   <">         =  <ASCII quote mark>           ; (     42,      34. )"
*)
let is_dquote = (=) '"'

let p_qtext state =
  p_while is_qtext state

(* See RFC 5322 § 3.2.4:

   qcontent        = qtext / quoted-pair
*)
let p_qcontent p state =
  match cur_chr state with
  | '\\' -> p_quoted_pair (fun chr -> p (String.make 1 chr)) state
  | chr when is_qtext chr -> p (p_qtext state) state
  | chr -> raise (Error.Error (Error.err_unexpected chr state))

(* See RFC 5322 § 3.2.4:

   quoted-string   = [CFWS]
                     DQUOTE *([FWS] qcontent) [FWS] DQUOTE
                     [CFWS]

   See RFC 822 § 3.3:

   quoted-string = <"> *(qtext/quoted-pair) <">; Regular qtext or
                                               ;   quoted chars.
*)
let p_quoted_string p state =
  let rec loop acc state =
    match cur_chr state with
    | '"' ->
      p_chr '"' state;
      p_cfws (fun _ -> p (List.rev acc |> String.concat "")) state
    | chr ->
      p_qcontent
        (fun str ->
         p_fws (fun has_wsp has_fws ->
                loop (if has_wsp then " " :: str :: acc else str :: acc)))
        state
  in
  p_cfws (fun _ state -> p_chr '"' state; loop [] state) state

(* See RFC 5234 § Appendix B.1:

   ALPHA           = %x41-5A / %x61-7A    ; A-Z / a-z

   See RFC 822 § 3.3:

   ALPHA       =  <any ASCII alphabetic character>
                                               ; (101-132, 65.- 90.)
*)
let is_alpha = function
  | '\x41' .. '\x5a'
  | '\x61' .. '\x7A' -> true
  | chr              -> false

(* See RFC 5234 § 3.4:

   DIGIT           = %x30-39

   See RFC 822 § 3.3:

   DIGIT       =  <any ASCII decimal digit>    ; ( 60- 71, 48.- 57. )
*)
let is_digit = function
  | '\x30' .. '\x39' -> true
  | chr              -> false

(* See RFC 5322 § 3.2.3:

   atext           = ALPHA / DIGIT /      ; Printable US-ASCII
                     "!" / "#" /          ;  characters not including
                     "$" / "%" /          ;  specials. Used for atoms.
                     "&" / "'" /
                     "*" / "+" /
                     "-" / "/" /
                     "=" / "?" /
                     "^" / "_" /
                     "`" / "{" /
                     "|" / "}" /
                     "~"
*)
let is_atext = function
  | '!' | '#'
  | '$' | '%'
  | '&' | '\''
  | '*' | '+'
  | '-' | '/'
  | '=' | '?'
  | '^' | '_'
  | '`' | '{'
  | '|' | '}'
  | '~' -> true
  | chr -> is_digit chr || is_alpha chr

let p_atext state = p_while is_atext state

(* See RFC 5322 § 3.2.3:

   atom            = [CFWS] 1*atext [CFWS]

   See RFC 822 § 3.3:

   atom        =  1*<any CHAR except specials, SPACE and CTLs>
*)
let p_atom p =
  p_cfws
  @@ fun _ state -> let atext = p_atext state in
                    p_cfws (fun _ -> p atext) state

(* See RFC 5322 § 3.2.5:

   word            = atom / quoted-string

   See RFC 822 § 3.3 (OH GOD! IT'S SAME):

   word        =  atom / quoted-string
*)
let p_word p state =
  let loop has_fws state =
    match cur_chr state with
    | '"' -> p_quoted_string (fun s -> p (`String s)) state
    | chr -> p_atom (fun s -> p (`Atom s)) state
  in

  p_cfws (fun has_fws -> loop has_fws) state

(* See RFC 5322 § 4.4:

   obs-local-part  = word *("." word)

   See RFC 822 § 6.1:

   local-part  =  word *("." word)             ; uninterpreted
                                               ; case-preserved
*)
let p_obs_local_part p =
  let rec loop acc state =
    match cur_chr state with
    | '.' -> junk_chr state; p_word (fun o -> loop (o :: acc)) state
    | chr -> p (List.rev acc) state
  in

  p_word (fun first -> loop [first])

(* See RFC 5322 § 3.2.3:

   dot-atom-text   = 1*atext *("." 1*atext)
*)
let p_dot_atom_text p state =
  let rec next acc state =
    match cur_chr state with
    | '.' -> junk_chr state; next (`Atom (p_atext state) :: acc) state
    | chr -> p (List.rev acc) state
  in

  next [`Atom (p_atext state)] state

(* See RFC 5322 § 3.2.3:

   dot-atom        = [CFWS] dot-atom-text [CFWS]
*)
let p_dot_atom p =
  p_cfws @@ (fun _ -> p_dot_atom_text (fun lst -> p_cfws (fun _ -> p lst)))

(* See RFC 5322 § 3.4.1:

   local-part      = dot-atom / quoted-string / obs-local-part

   XXX: same as domain

   See RFC 822 § 6.1:

   local-part  =  word *("." word)             ; uninterpreted
                                               ; case-preserved
*)
let p_local_part p =
  let p_obs_local_part' acc =
    let rec loop acc state =
      match cur_chr state with
      | '.' -> junk_chr state; p_word (fun o -> loop (o :: acc)) state
      | chr -> p (List.rev acc) state
    in

    p_cfws (fun _ -> loop acc)
  in

  p_cfws (fun _ state ->
    match cur_chr state with
    | '"' -> p_quoted_string (fun s -> p_obs_local_part' [`String s]) state
             (* XXX: may be we should continue because it's [word] from
                     [obs-local-part] and it's not just [quoted-string]. *)
    | chr ->
      (* dot-atom / obs-local-part *)
      p_try_rule
        (function
          | [] -> p_obs_local_part p
          | l  -> p_obs_local_part' (List.rev l))
        (p_obs_local_part p)
        (p_dot_atom (fun l state -> `Ok (l, state)))
        state)

(* See RFC 5322 § 3.4.1 & 4.4:

   dtext           = %d33-90 /            ; Printable US-ASCII
                     %d94-126 /           ;  characters not including
                     obs-dtext            ;  "[", "]", or %x5C
   obs-dtext       = obs-NO-WS-CTL / quoted-pair

   See RFC 822 § 3.3:

   dtext       =  <any CHAR excluding "[",     ; => may be folded
                   "]", %x5C & CR, & including
                   linear-white-space>
*)
let is_dtext = function
  | '\033' .. '\090'
  | '\094' .. '\126' -> true
  | chr -> is_obs_no_ws_ctl chr

let p_dtext p state =
  let rec loop acc state =
    match cur_chr state with
    | '\033' .. '\090'
    | '\094' .. '\126' ->
      let s = p_while is_dtext state in
      loop (s :: acc) state
    | chr when is_obs_no_ws_ctl chr ->
      let s = p_while is_dtext state in
      loop (s :: acc) state
    | '\\' ->
      p_quoted_pair
        (fun chr state -> loop (String.make 1 chr :: acc) state) state
    | chr -> p (List.rev acc |> String.concat "") state
  in

  loop [] state

(* See RFC 5322 § 4.4:

   obs-domain      = atom *("." atom)

   See RFC 822 § 3.3 & 6.1:

   domain-literal =  "[" *(dtext / quoted-pair) "]"
   domain      =  sub-domain *("." sub-domain)
   sub-domain  =  domain-ref / domain-literal
*)
let p_obs_domain p =
  let rec loop acc state =
    match cur_chr state with
    | '.' -> junk_chr state; p_atom (fun o -> loop (`Atom o :: acc)) state
    | chr -> p (List.rev acc) state
  in

  p_atom (fun first -> loop [`Atom first])

(* See RFC 5322 § 3.4.1:

   domain-literal   = [CFWS] "[" *([FWS] dtext) [FWS] "]" [CFWS]

   See RFC 822 § 3.3:

   domain-literal =  "[" *(dtext / quoted-pair) "]"
*)
let p_domain_literal p =
  let rec loop acc state =
    match cur_chr state with
    | ']' ->
      p_chr ']' state;
      p_cfws (fun _ -> p (List.rev acc |> String.concat "")) state
    | chr when is_dtext chr || chr = '\\' ->
      p_dtext (fun s -> p_fws (fun _ _ -> loop (s :: acc))) state
    | chr -> raise (Error.Error (Error.err_unexpected chr state))
  in

  p_cfws (fun _ state ->
          match cur_chr state with
          | '[' -> p_chr '[' state; p_fws (fun _ _ -> loop []) state
          | chr -> raise (Error.Error (Error.err_expected '[' state)))

(* See RFC 5322 § 3.4.1:

   domain          = dot-atom / domain-literal / obs-domain

   See RFC 822 § 3.3 & 6.1:

   domain-literal =  "[" *(dtext / quoted-pair) "]"
   domain      =  sub-domain *("." sub-domain)
   sub-domain  =  domain-ref / domain-literal
*)
let p_domain p =
  let p_obs_domain' p =
    let rec loop acc state =
      match cur_chr state with
      | '.' ->
        junk_chr state;
        p_atom (fun o -> loop (`Atom o :: acc)) state
      | chr -> p (List.rev acc) state
    in

    p_cfws (fun _ -> loop [])
  in

  (* XXX: dot-atom, domain-literal or obs-domain start with [CFWS] *)
  p_cfws (fun _ state ->
    match cur_chr state with
    (* it's domain-literal *)
    | '[' -> p_domain_literal (fun s -> p (`Literal s)) state
    (* it's dot-atom or obs-domain *)
    | chr ->
      p_dot_atom   (* may be we are [CFWS] allowed by obs-domain *)
        (function
         (* if we have an empty list, we need at least one atom *)
         | [] -> p_obs_domain (fun domain -> p (`Domain domain))
         (* in other case, we have at least one atom *)
         | l1 -> p_obs_domain' (fun l2 -> p (`Domain (l1 @ l2)))) state)

(* See RFC 5322 § 3.6.4 & 4.5.4:

   id-left         = dot-atom-text / obs-id-left
   obs-id-left     = local-part
*)
let p_obs_id_left = p_local_part

let p_id_left p state =
  p_try_rule p
    (p_obs_id_left p)
    (p_dot_atom_text (fun data state -> `Ok (data, state)))
    state

    (* See RFC 5322 § 3.6.4 & 4.5.4:

   id-right        = dot-atom-text / no-fold-literal / obs-id-right
   no-fold-literal = "[" *dtext "]"
   obs-id-right    =   domain
*)
let p_obs_id_right = p_domain

let p_no_fold_literal p state =
  p_chr '[' state;
  p_dtext (fun d state -> p_chr ']' state; p (`Literal d) state) state

let p_id_right p state =
  p_try_rule p
    (p_try_rule p
       (p_obs_id_right p)
       (p_no_fold_literal (fun data state -> `Ok (data, state))))
    (p_dot_atom_text (fun data state -> `Ok (`Domain data, state)))
    state

(* See RFC 5322 § 3.6.4:

   msg-id          = [CFWS] "<" id-left "@" id-right ">" [CFWS]

   See RFC 822 § 4.1 & 6.1:

   addr-spec   =  local-part "@" domain        ; global address
   msg-id      =  "<" addr-spec ">"            ; Unique message id
*)
let p_msg_id p state =
  p_cfws (fun _ state ->
    p_chr '<' state;
    p_id_left (fun left state ->
      p_chr '@' state;
      p_id_right (fun right state ->
        p_chr '>' state;
        p_cfws (fun _ -> p (left, right)) state)
      state)
    state)
  state

let p_crlf p state =
  p_chr '\r' state;
  p_chr '\n' state;

  p state
