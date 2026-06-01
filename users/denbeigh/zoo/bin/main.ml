let () =
  let reporter = Logs.format_reporter () in
  let () = Logs.set_level (Some App) in
  let () = Logs.set_reporter reporter in
  Zoo.run ()
;;
