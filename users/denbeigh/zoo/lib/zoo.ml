open Core
module Scanner = Scanner

let ls () =
  let dir = "." in
  let families = Scanner.model_dirs dir in
  List.iter families ~f:(fun (name, family) ->
    printf "%s\n" name;
    printf "  Models:\n";
    List.iter family.model_paths ~f:(fun (_, location) ->
      let display_name =
        match location with
        | Single_file fname -> fname
        | Multi_file (dirname, _) -> dirname
      in
      printf "    - %s\n" display_name);
    printf "  Mmproj:\n";
    List.iter family.mmproj_paths ~f:(fun path -> printf "    - %s\n" path))
;;

let hello () = print_endline "Hello, world!"

let run () =
  let cmd =
    Command.group
      ~summary:"Zoo CLI"
      [ ( "ls"
        , Command.basic
            ~summary:"List model families"
            (Command.Param.return (fun () -> ls ())) )
      ; ( "hello"
        , Command.basic ~summary:"Say hello" (Command.Param.return (fun () -> hello ())) )
      ]
  in
  Command_unix.run cmd
;;
