type model_location =
  (* path to the single .gguf file *)
  | Single_file of string
  (* path to the containing directory, and list of filenames in that directory *)
  | Multi_file of (string * string list)

(* A discovered directory of a model, with quantisations and potentially mmproj
     files inside *)
type model_family =
  { name : string
  ; dir_path : string
  ; mmproj_paths : string list
  ; model_paths : (string * model_location) list
  }

(* A specific variant of a model, with a selected model and (optionally)
     mmproj, that will be used to launch an instance of `llama-server` *)
type model_configuration =
  { family_name : string
  ; model_location : model_location
  ; mmproj_path : string option
  }
