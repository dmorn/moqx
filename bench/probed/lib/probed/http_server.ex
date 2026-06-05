defmodule Probed.HTTPServer do
  @moduledoc false

  use GenServer

  alias Probed.Config

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def port(server) do
    GenServer.call(server, :port)
  end

  @impl GenServer
  def init(opts) do
    config = Config.from_map!(Keyword.fetch!(opts, :config))
    File.mkdir_p!(config.work_dir)
    File.mkdir_p!(Path.join(config.work_dir, "runs"))

    {:ok, ip} = config.bind_host |> String.to_charlist() |> :inet.parse_address()

    {:ok, listen_socket} =
      :gen_tcp.listen(config.bind_port, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: ip
      ])

    {:ok, {_ip, port}} = :inet.sockname(listen_socket)
    server = self()
    acceptor = spawn_link(fn -> accept_loop(server, listen_socket) end)

    {:ok,
     %{
       config: config,
       listen_socket: listen_socket,
       port: port,
       acceptor: acceptor,
       runs: %{}
     }}
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  def handle_call({:request, request}, _from, state) do
    {response, state} =
      if authorized?(request, state.config) do
        route(request, state)
      else
        {json_response(401, %{"error" => "unauthorized"}), state}
      end

    {:reply, response, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    {:noreply,
     update_process_by_port(state, port, fn process ->
       File.write!(process.stdout_path, data, [:append])
       process
     end)}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    {:noreply, update_process_by_port(state, port, &exit_process(&1, status, "exited"))}
  end

  def handle_info({:process_timeout, run_id, process_id}, state) do
    {:noreply,
     update_process(state, run_id, process_id, fn
       %{state: state_name} = process when state_name in ["exited", "timed_out", "failed"] ->
         process

       process ->
         if is_port(process.port), do: Port.close(process.port)
         exit_process(process, nil, "timed_out")
     end)}
  end

  defp accept_loop(server, listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn_link(fn -> serve(server, socket) end)
        accept_loop(server, listen_socket)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(server, socket) do
    response =
      case read_request(socket) do
        {:ok, request} -> GenServer.call(server, {:request, request}, 30_000)
        {:error, reason} -> json_response(400, %{"error" => to_string(reason)})
      end

    :ok = :gen_tcp.send(socket, encode_response(response))
    :ok = :gen_tcp.close(socket)
  end

  defp read_request(socket) do
    with {:ok, raw} <- recv_headers(socket, "") do
      parse_request(raw)
    end
  end

  defp recv_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, data} -> recv_headers(socket, acc <> data)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_request(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head, "\r\n", trim: true)
    [method, path, _version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    {:ok, %{method: method, path: path, headers: headers, body: body}}
  rescue
    _error -> {:error, :bad_request}
  end

  defp authorized?(request, config) do
    request.headers["authorization"] == "Bearer #{config.token}"
  end

  defp route(%{method: "GET", path: "/v1/health"}, %{config: config} = state) do
    {json_response(200, %{
       "status" => "ok",
       "node_id" => config.node_id,
       "version" => List.to_string(Probed.version())
     }), state}
  end

  defp route(%{method: "GET", path: "/v1/node"}, %{config: config} = state) do
    {json_response(200, %{
       "node_id" => config.node_id,
       "work_dir" => config.work_dir
     }), state}
  end

  defp route(%{method: "GET", path: "/v1/tools"}, %{config: config} = state) do
    tools =
      Map.new(config.tools, fn {name, %{"path" => path}} ->
        {name,
         %{
           "path" => path,
           "exists" => File.exists?(path),
           "executable" => executable?(path)
         }}
      end)

    {json_response(200, %{"tools" => tools}), state}
  end

  defp route(%{method: "POST", path: "/v1/runs"} = request, state) do
    with {:ok, body} <- json_body(request),
         {:ok, run_id} <- fetch_safe_run_id(body),
         false <- Map.has_key?(state.runs, run_id) do
      metadata = Map.get(body, "metadata", %{})
      run_dir = run_dir(state.config, run_id)
      File.mkdir_p!(Path.join(run_dir, "processes"))
      File.mkdir_p!(Path.join(run_dir, "artifacts"))

      run = %{
        run_id: run_id,
        state: "active",
        metadata: metadata,
        run_dir: run_dir,
        processes: %{}
      }

      write_json!(Path.join(run_dir, "run.json"), public_run(run))
      write_json!(Path.join(run_dir, "node.json"), node_metadata(state.config))

      state = put_in(state.runs[run_id], run)
      {json_response(201, public_run(run)), state}
    else
      true -> {json_response(409, %{"error" => "run_exists"}), state}
      {:error, reason} -> {json_response(422, %{"error" => reason}), state}
    end
  end

  defp route(%{method: "GET", path: path}, state) do
    path
    |> String.split("/", trim: true)
    |> route_get(state)
  end

  defp route(%{method: "POST", path: path} = request, state) do
    case String.split(path, "/", trim: true) do
      ["v1", "runs", run_id, "processes"] ->
        with {:ok, body} <- json_body(request),
             {:ok, run} <- fetch_run(state, run_id),
             {:ok, process, run} <- start_process(state.config, run, body) do
          state = put_in(state.runs[run_id], run)
          {json_response(201, public_process(process)), state}
        else
          {:error, reason} -> {json_response(422, %{"error" => reason}), state}
        end

      _other ->
        {json_response(404, %{"error" => "not_found"}), state}
    end
  end

  defp route(%{method: "DELETE", path: path}, state) do
    case String.split(path, "/", trim: true) do
      ["v1", "runs", run_id] ->
        with {:ok, run} <- fetch_run(state, run_id),
             :ok <- ensure_no_running_processes(run) do
          File.rm_rf!(run.run_dir)
          state = update_in(state.runs, &Map.delete(&1, run_id))
          {json_response(200, %{"run_id" => run_id, "state" => "cleaned"}), state}
        else
          {:error, "run_has_active_processes"} ->
            {json_response(409, %{"error" => "run_has_active_processes"}), state}

          {:error, reason} ->
            {json_response(404, %{"error" => reason}), state}
        end

      ["v1", "runs", run_id, "processes", process_id] ->
        state =
          update_process(state, run_id, process_id, fn process ->
            if is_port(process.port), do: Port.close(process.port)
            %{process | state: "stopping"}
          end)

        case fetch_process(state, run_id, process_id) do
          {:ok, process} -> {json_response(200, public_process(process)), state}
          {:error, reason} -> {json_response(404, %{"error" => reason}), state}
        end

      _other ->
        {json_response(404, %{"error" => "not_found"}), state}
    end
  end

  defp route(_request, state), do: {json_response(404, %{"error" => "not_found"}), state}

  defp route_get(["v1", "runs", run_id], state) do
    case fetch_run(state, run_id) do
      {:ok, run} -> {json_response(200, public_run(run)), state}
      {:error, reason} -> {json_response(404, %{"error" => reason}), state}
    end
  end

  defp route_get(["v1", "runs", run_id, "processes"], state) do
    case fetch_run(state, run_id) do
      {:ok, run} ->
        processes = run.processes |> Map.values() |> Enum.map(&public_process/1)
        {json_response(200, %{"processes" => processes}), state}

      {:error, reason} ->
        {json_response(404, %{"error" => reason}), state}
    end
  end

  defp route_get(["v1", "runs", run_id, "processes", process_id], state) do
    case fetch_process(state, run_id, process_id) do
      {:ok, process} -> {json_response(200, public_process(process)), state}
      {:error, reason} -> {json_response(404, %{"error" => reason}), state}
    end
  end

  defp route_get(["v1", "runs", run_id, "artifacts"], state) do
    case fetch_run(state, run_id) do
      {:ok, run} -> {json_response(200, %{"artifacts" => list_run_files(run.run_dir)}), state}
      {:error, reason} -> {json_response(404, %{"error" => reason}), state}
    end
  end

  defp route_get(["v1", "runs", run_id, "artifacts" | artifact_parts], state) do
    with {:ok, run} <- fetch_run(state, run_id),
         {:ok, path} <- safe_run_path(run.run_dir, Path.join(artifact_parts)),
         true <- File.regular?(path) do
      {file_response(200, File.read!(path), content_type(path)), state}
    else
      false -> {json_response(404, %{"error" => "artifact_not_found"}), state}
      {:error, reason} -> {json_response(404, %{"error" => reason}), state}
    end
  end

  defp route_get(["v1", "runs", run_id, "bundle"], state) do
    with {:ok, run} <- fetch_run(state, run_id),
         {:ok, bundle} <- bundle(run.run_dir) do
      {file_response(200, bundle, "application/gzip"), state}
    else
      {:error, reason} -> {json_response(404, %{"error" => reason}), state}
    end
  end

  defp route_get(_path, state), do: {json_response(404, %{"error" => "not_found"}), state}

  defp executable?(path), do: System.find_executable(path) == path

  defp json_body(%{body: body}) do
    case Jason.decode(body || "") do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, "json_body_must_be_object"}
      {:error, _error} -> {:error, "invalid_json"}
    end
  end

  defp fetch_safe_run_id(%{"run_id" => run_id}) when is_binary(run_id) do
    if Regex.match?(~r/^[A-Za-z0-9_.:-]+$/, run_id) do
      {:ok, run_id}
    else
      {:error, "invalid_run_id"}
    end
  end

  defp fetch_safe_run_id(_body), do: {:error, "missing_run_id"}

  defp fetch_run(state, run_id) do
    case Map.fetch(state.runs, run_id) do
      {:ok, run} -> {:ok, run}
      :error -> {:error, "run_not_found"}
    end
  end

  defp fetch_process(state, run_id, process_id) do
    with {:ok, run} <- fetch_run(state, run_id) do
      case Map.fetch(run.processes, process_id) do
        {:ok, process} -> {:ok, process}
        :error -> {:error, "process_not_found"}
      end
    end
  end

  defp start_process(config, run, body) do
    with {:ok, role} <- fetch_allowed_role(body),
         {:ok, tool_name} <- fetch_string(body, "tool"),
         {:ok, tool} <- fetch_tool(config, tool_name),
         {:ok, argv} <- fetch_argv(body),
         {:ok, timeout_ms} <- fetch_timeout(body),
         {:ok, artifacts} <- fetch_artifacts(body) do
      process_id = "process-#{System.unique_integer([:positive, :monotonic])}"
      process_dir = Path.join([run.run_dir, "processes", process_id])
      File.mkdir_p!(process_dir)

      stdout_path = Path.join(process_dir, "stdout.log")
      stderr_path = Path.join(process_dir, "stderr.log")
      File.touch!(stdout_path)
      File.touch!(stderr_path)

      process = %{
        process_id: process_id,
        role: role,
        tool: tool_name,
        argv: argv,
        artifacts: artifacts,
        state: "running",
        exit_status: nil,
        port: nil,
        timeout_ref: nil,
        process_dir: process_dir,
        stdout_path: stdout_path,
        stderr_path: stderr_path
      }

      command = public_process(process) |> Map.put("command", [tool["path"] | argv])
      write_json!(Path.join(process_dir, "command.json"), command)

      port =
        Port.open({:spawn_executable, tool["path"]}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, argv}
        ])

      timeout_ref =
        if timeout_ms do
          Process.send_after(self(), {:process_timeout, run.run_id, process_id}, timeout_ms)
        end

      process = %{process | port: port, timeout_ref: timeout_ref}
      run = put_in(run.processes[process_id], process)
      {:ok, process, run}
    end
  end

  defp fetch_allowed_role(body) do
    allowed = ~w(baseline_server baseline_client reference_server reference_client moqx_client)

    with {:ok, role} <- fetch_string(body, "role"),
         true <- role in allowed do
      {:ok, role}
    else
      false -> {:error, "invalid_role"}
      error -> error
    end
  end

  defp fetch_string(body, key) do
    case Map.fetch(body, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, "missing_#{key}"}
    end
  end

  defp fetch_tool(config, tool_name) do
    case Map.fetch(config.tools, tool_name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, "unknown_tool"}
    end
  end

  defp fetch_argv(body) do
    case Map.get(body, "argv") do
      argv when is_list(argv) -> fetch_argv_list(argv)
      _other -> {:error, "invalid_argv"}
    end
  end

  defp fetch_argv_list(argv) do
    if Enum.all?(argv, &is_binary/1) do
      {:ok, argv}
    else
      {:error, "invalid_argv"}
    end
  end

  defp fetch_timeout(body) do
    case Map.get(body, "timeout_ms") do
      nil -> {:ok, nil}
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      _other -> {:error, "invalid_timeout_ms"}
    end
  end

  defp fetch_artifacts(body) do
    artifacts = Map.get(body, "artifacts", %{})

    cond do
      !is_map(artifacts) ->
        {:error, "invalid_artifacts"}

      Enum.all?(artifacts, fn {_name, path} -> is_binary(path) and safe_relative_path?(path) end) ->
        {:ok, artifacts}

      true ->
        {:error, "invalid_artifacts"}
    end
  end

  defp run_dir(config, run_id), do: Path.join([config.work_dir, "runs", run_id])

  defp node_metadata(config) do
    %{
      "node_id" => config.node_id,
      "work_dir" => config.work_dir,
      "tools" => Map.keys(config.tools)
    }
  end

  defp public_run(run) do
    %{
      "run_id" => run.run_id,
      "state" => run.state,
      "metadata" => run.metadata
    }
  end

  defp public_process(process) do
    %{
      "process_id" => process.process_id,
      "role" => process.role,
      "tool" => process.tool,
      "argv" => process.argv,
      "state" => process.state,
      "exit_status" => process.exit_status,
      "artifacts" => process.artifacts
    }
  end

  defp exit_process(process, status, state_name) do
    if process.timeout_ref, do: Process.cancel_timer(process.timeout_ref)

    process = %{process | state: state_name, exit_status: status, port: nil, timeout_ref: nil}
    write_json!(Path.join(process.process_dir, "exit.json"), public_process(process))
    process
  end

  defp update_process_by_port(state, port, fun) do
    update_process_matching(state, fn process -> process.port == port end, fun)
  end

  defp update_process(state, run_id, process_id, fun) do
    update_in(state.runs[run_id].processes[process_id], fn
      nil -> nil
      process -> fun.(process)
    end)
  end

  defp update_process_matching(state, predicate, fun) do
    update_in(state.runs, fn runs ->
      Map.new(runs, fn {run_id, run} ->
        {run_id, update_matching_processes(run, predicate, fun)}
      end)
    end)
  end

  defp update_matching_processes(run, predicate, fun) do
    processes =
      Map.new(run.processes, fn entry ->
        update_process_entry(entry, predicate, fun)
      end)

    %{run | processes: processes}
  end

  defp update_process_entry({process_id, process}, predicate, fun) do
    process =
      if predicate.(process) do
        fun.(process)
      else
        process
      end

    {process_id, process}
  end

  defp ensure_no_running_processes(run) do
    if Enum.any?(run.processes, fn {_id, process} -> process.state in ["running", "starting"] end) do
      {:error, "run_has_active_processes"}
    else
      :ok
    end
  end

  defp list_run_files(run_dir) do
    run_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, run_dir))
    |> Enum.sort()
  end

  defp safe_run_path(run_dir, relative_path) do
    if safe_relative_path?(relative_path) do
      root = Path.expand(run_dir)
      path = Path.expand(Path.join(root, relative_path))

      if path == root or String.starts_with?(path, root <> "/") do
        {:ok, path}
      else
        {:error, "invalid_path"}
      end
    else
      {:error, "invalid_path"}
    end
  end

  defp safe_relative_path?(path) when is_binary(path) do
    Path.type(path) == :relative and
      path != "" and
      not Enum.member?(Path.split(path), "..")
  end

  defp bundle(run_dir) do
    tar_path =
      Path.join(System.tmp_dir!(), "probed-bundle-#{System.unique_integer([:positive])}.tar.gz")

    files = list_run_files(run_dir) |> Enum.map(&String.to_charlist/1)

    result =
      File.cd!(run_dir, fn ->
        :erl_tar.create(String.to_charlist(tar_path), files, [:compressed])
      end)

    case result do
      :ok ->
        bundle = File.read!(tar_path)
        File.rm(tar_path)
        {:ok, bundle}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp write_json!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(value, pretty: true))
  end

  defp content_type(path) do
    case Path.extname(path) do
      ".json" -> "application/json"
      ".jsonl" -> "application/x-ndjson"
      ".log" -> "text/plain"
      _other -> "application/octet-stream"
    end
  end

  defp json_response(status, body) do
    file_response(status, Jason.encode!(body), "application/json")
  end

  defp file_response(status, body, content_type) do
    %{status: status, headers: %{"Content-Type" => content_type}, body: body}
  end

  defp encode_response(%{status: status, headers: headers, body: body}) do
    reason = reason(status)
    headers = Map.put(headers, "Content-Length", byte_size(body))

    encoded_headers =
      Enum.map_join(headers, "", fn {key, value} -> "#{key}: #{value}\r\n" end)

    "HTTP/1.1 #{status} #{reason}\r\n#{encoded_headers}\r\n#{body}"
  end

  defp reason(200), do: "OK"
  defp reason(201), do: "Created"
  defp reason(400), do: "Bad Request"
  defp reason(401), do: "Unauthorized"
  defp reason(404), do: "Not Found"
  defp reason(409), do: "Conflict"
  defp reason(422), do: "Unprocessable Content"
end
