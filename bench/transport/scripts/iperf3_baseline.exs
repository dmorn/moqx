project_dir = Path.expand("..", __DIR__)
argv = System.argv()
argv = if List.first(argv) == "--", do: tl(argv), else: argv

{_output, status} =
  System.cmd(
    "mix",
    ["moqx.transport.iperf3_baseline" | argv],
    cd: project_dir,
    into: IO.stream(:stdio, :line),
    stderr_to_stdout: true
  )

System.halt(status)
