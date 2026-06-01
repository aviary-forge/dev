open! Core
open! Core_unix
open! Zoo

let test_scanner () =
  let tmp = Core_unix.mkdtemp "/tmp/scanner_test" in
  let () =
    (* Set up test fixtures *)
    let create_file path =
      let ch = Out_channel.create path in
      Out_channel.close ch
    in
    (* Create model_dir with .gguf file *)
    Core_unix.mkdir (tmp ^ "/model_dir");
    create_file (tmp ^ "/model_dir/test.gguf");
    (* Create visible subdirectory with .gguf file *)
    Core_unix.mkdir (tmp ^ "/visible_dir");
    create_file (tmp ^ "/visible_dir/test.gguf");
    (* Create hidden directory with .gguf file *)
    Core_unix.mkdir (tmp ^ "/.hidden_dir");
    create_file (tmp ^ "/.hidden_dir/test.gguf");
    (* Create empty directory *)
    Core_unix.mkdir (tmp ^ "/empty_dir")
  in
  let result = Scanner.scan_dir tmp in
  assert result
;;

let () = test_scanner ()
