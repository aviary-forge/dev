open Core
open Families

let contains_gguf dir =
  let names = Sys_unix.readdir dir in
  Array.exists names ~f:(fun name -> String.is_suffix ~suffix:".gguf" name)
;;

let is_dir_entry entry =
  match Sys_unix.is_directory entry with
  | `Yes -> true
  | `No -> false
  | `Unknown ->
    (* TODO: log a warning here *)
    false
;;

let is_visible entry = not (String.is_prefix ~prefix:"." entry)

let rec is_model_dir ~depth dir =
  if contains_gguf dir
  then true
  else if depth >= 2
  then false
  else (
    let names = Sys_unix.readdir dir in
    Array.exists names ~f:(fun name ->
      let child_path = dir ^ "/" ^ name in
      let is_gguf = String.is_suffix ~suffix:".gguf" name in
      let is_dir = is_dir_entry child_path in
      if is_gguf
      then true
      else if is_dir
      then (
        let is_visible = is_visible name in
        if is_visible then is_model_dir ~depth:(depth + 1) child_path else false)
      else false))
;;

let is_model_dir dir = is_model_dir ~depth:0 dir

let scan_dir dir =
  if is_model_dir dir
  then true
  else (
    let names = Sys_unix.readdir dir |> Array.to_list in
    let rec loop names =
      match names with
      | [] -> false
      | name :: rest ->
        let entry_path = dir ^ "/" ^ name in
        let is_dir = is_dir_entry entry_path in
        let is_visible = is_visible name in
        if is_dir && is_visible then loop rest else false
    in
    loop names)
;;

let strip_gguf_suffix name =
  if String.is_suffix ~suffix:".gguf" name then Some (String.drop_suffix name 5) else None
;;

let classify_files dir names =
  let names_list = Array.to_list names in
  let model_paths =
    names_list
    |> List.filter_map ~f:(fun name ->
      let path = dir ^ "/" ^ name in
      if is_dir_entry path
      then (
        let subdir_names = Sys_unix.readdir path in
        let subdir_names_list = Array.to_list subdir_names in
        let has_gguf =
          Array.exists subdir_names ~f:(fun n -> String.is_suffix ~suffix:".gguf" n)
        in
        if has_gguf then Some (name, Multi_file (name, subdir_names_list)) else None)
      else if
        String.is_suffix ~suffix:".gguf" name
        && not (String.is_prefix ~prefix:"mmproj-" name)
      then (
        match strip_gguf_suffix name with
        | Some s -> Some (s, Single_file name)
        | None -> None)
      else None)
  in
  let mmproj_filenames =
    names_list
    |> List.filter_map ~f:(fun name ->
      if String.is_suffix ~suffix:".gguf" name && String.is_prefix ~prefix:"mmproj-" name
      then (
        match strip_gguf_suffix name with
        | Some s -> Some s
        | None -> None)
      else None)
  in
  model_paths, mmproj_filenames
;;

let scan_model_dir dir =
  if not (scan_dir dir)
  then None
  else (
    let names = Sys_unix.readdir dir in
    let model_paths, mmproj_paths = classify_files dir names in
    let name = Filename.basename dir in
    Some { name; dir_path = dir; mmproj_paths; model_paths })
;;

let model_dirs pwd =
  let names = Sys_unix.readdir pwd |> Array.to_list in
  let rec loop names acc =
    match names with
    | [] -> List.rev acc
    | name :: rest ->
      let entry_path = pwd ^ "/" ^ name in
      let is_dir = is_dir_entry entry_path in
      let is_visible = is_visible name in
      if is_dir && is_visible
      then (
        let model_path = pwd ^ "/" ^ name in
        match scan_model_dir model_path with
        | Some family -> loop rest ((name, family) :: acc)
        | None -> loop rest acc)
      else loop rest acc
  in
  loop names []
;;
