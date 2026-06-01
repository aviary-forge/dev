val run : unit -> unit

module Scanner : sig
  val is_model_dir : string -> bool
  val model_dirs : string -> (string * Families.model_family) list
  val scan_dir : string -> bool
  val scan_model_dir : string -> Families.model_family option

  val classify_files
    :  string
    -> string array
    -> (string * Families.model_location) list * string list
end
