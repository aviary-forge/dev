(* Checks if a directory contains .gguf files or has subdirectories with .gguf files *)
val is_model_dir : string -> bool

(* Returns top-level subdirectories that contain model families with their metadata *)
val model_dirs : string -> (string * Families.model_family) list

(* Recursively checks if a directory contains model files (.gguf) or has visible subdirectories with model files *)
val scan_dir : string -> bool

(* Scans a single model directory and returns its metadata if valid *)
val scan_model_dir : string -> Families.model_family option

(* Classifies files in a directory into model paths and mmproj paths *)
val classify_files
  :  string
  -> string array
  -> (string * Families.model_location) list * string list
