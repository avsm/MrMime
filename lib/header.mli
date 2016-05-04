type t

val of_string : string -> t
val to_string : t -> string
val of_lexer  : ([> Rfc5322.field ] as 'field) list -> (t option -> 'field list -> Lexer.t -> 'a) -> Lexer.t -> 'a

val equal     : t -> t -> bool
val pp        : Format.formatter -> t -> unit
