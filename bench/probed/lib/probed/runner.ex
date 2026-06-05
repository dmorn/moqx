defmodule Probed.Runner do
  @moduledoc false

  use GenServer

  alias Probed.Config

  @active_process_states ~w(starting ready running stopping)
  @terminal_process_states ~w(exited failed timed_out)

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def token(server), do: GenServer.call(server, :token)
  def health(server), do: GenServer.call(server, :health)
  def node(server), do: GenServer.call(server, :node)
  def tools(server), do: GenServer.call(server, :tools)
  def create_run(server, body), do: GenServer.call(server, {:create_run, body})
  def run(server, run_id), do: GenServer.call(server, {:run, run_id})
  def processes(server, run_id), do: GenServer.call(server, {:processes, run_id})

  def process(server, run_id, process_id),
    do: GenServer.call(server, {:process, run_id, process_id})

  def start_process(server, run_id, body),
    do: GenServer.call(server, {:start_process, run_id, body})

  def stop_process(server, run_id, process_id),
    do: GenServer.call(server, {:stop_process, run_id, process_id})

  def delete_run(server, run_id), do: GenServer.call(server, {:delete_run, run_id})
  def artifacts(server, run_id), do: GenServer.call(server, {:artifacts, run_id})

  def artifact(server, run_id, artifact_parts),
    do: GenServer.call(server, {:artifact, run_id, artifact_parts})

  def bundle(server, run_id), do: GenServer.call(server, {:bundle, run_id})

  @impl GenServer
  def init(opts) do
    config = config!(Keyword.fetch!(opts, :config))
    File.mkdir_p!(config.work_dir)
    File.mkdir_p!(Path.join(config.work_dir, "runs"))

    {:ok,
     %{
       config: config,
       runs: %{}
     }}
  end

  defp config!(%Config{} = config), do: config
  defp config!(config), do: Config.from_map!(config)

  @impl GenServer
  def handle_call(:token, _from, state) do
    {:reply, state.config.token, state}
  end

  def handle_call(:health, _from, state) do
    response = %{
      "status" => "ok",
      "node_id" => state.config.node_id,
      "version" => List.to_string(Probed.version())
    }

    {:reply, {:ok, response}, state}
  end

  def handle_call(:node, _from, state) do
    response = %{
      "node_id" => state.config.node_id,
      "work_dir" => state.config.work_dir
    }

    {:reply, {:ok, response}, state}
  end

  def handle_call(:tools, _from, state) do
    tools =
      Map.new(state.config.tools, fn {name, %{"path" => path}} ->
        {name,
         %{
           "path" => path,
           "exists" => File.exists?(path),
           "executable" => executable?(path)
         }}
      end)

    {:reply, {:ok, %{"tools" => tools}}, state}
  end

  def handle_call({:create_run, body}, _from, state) do
    {response, state} = create_run_state(state, body)
    {:reply, response, state}
  end

  def handle_call({:run, run_id}, _from, state) do
    response =
      case fetch_run(state, run_id) do
        {:ok, run} -> {:ok, public_run(run)}
        {:error, reason} -> {:error, 404, reason}
      end

    {:reply, response, state}
  end

  def handle_call({:processes, run_id}, _from, state) do
    response =
      case fetch_run(state, run_id) do
        {:ok, run} ->
          processes = run.processes |> Map.values() |> Enum.map(&public_process/1)
          {:ok, %{"processes" => processes}}

        {:error, reason} ->
          {:error, 404, reason}
      end

    {:reply, response, state}
  end

  def handle_call({:process, run_id, process_id}, _from, state) do
    response =
      case fetch_process(state, run_id, process_id) do
        {:ok, process} -> {:ok, public_process(process)}
        {:error, reason} -> {:error, 404, reason}
      end

    {:reply, response, state}
  end

  def handle_call({:start_process, run_id, body}, _from, state) do
    {response, state} =
      with {:ok, run} <- fetch_run(state, run_id),
           {:ok, process, run} <- start_process_state(state.config, run, body) do
        state = put_in(state.runs[run_id], run)
        {{:ok, 201, public_process(process)}, state}
      else
        {:error, reason} -> {{:error, 422, reason}, state}
      end

    {:reply, response, state}
  end

  def handle_call({:stop_process, run_id, process_id}, _from, state) do
    state =
      update_process(state, run_id, process_id, fn process ->
        terminate_process(process)
        %{process | state: "stopping"}
      end)

    response =
      case fetch_process(state, run_id, process_id) do
        {:ok, process} -> {:ok, public_process(process)}
        {:error, reason} -> {:error, 404, reason}
      end

    {:reply, response, state}
  end

  def handle_call({:delete_run, run_id}, _from, state) do
    {response, state} =
      with {:ok, run} <- fetch_run(state, run_id),
           :ok <- ensure_no_running_processes(run) do
        File.rm_rf!(run.run_dir)
        state = update_in(state.runs, &Map.delete(&1, run_id))
        {{:ok, %{"run_id" => run_id, "state" => "cleaned"}}, state}
      else
        {:error, "run_has_active_processes"} -> {{:error, 409, "run_has_active_processes"}, state}
        {:error, reason} -> {{:error, 404, reason}, state}
      end

    {:reply, response, state}
  end

  def handle_call({:artifacts, run_id}, _from, state) do
    response =
      case fetch_run(state, run_id) do
        {:ok, run} -> {:ok, %{"artifacts" => list_run_files(run.run_dir)}}
        {:error, reason} -> {:error, 404, reason}
      end

    {:reply, response, state}
  end

  def handle_call({:artifact, run_id, artifact_parts}, _from, state) do
    response =
      with {:ok, run} <- fetch_run(state, run_id),
           {:ok, path} <- safe_run_path(run.run_dir, Path.join(artifact_parts)),
           true <- File.regular?(path) do
        {:file, File.read!(path), content_type(path)}
      else
        false -> {:error, 404, "artifact_not_found"}
        {:error, reason} -> {:error, 404, reason}
      end

    {:reply, response, state}
  end

  def handle_call({:bundle, run_id}, _from, state) do
    response =
      with {:ok, run} <- fetch_run(state, run_id),
           {:ok, bundle} <- bundle(run.run_dir) do
        {:file, bundle, "application/gzip"}
      else
        {:error, reason} -> {:error, 404, reason}
      end

    {:reply, response, state}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    {:noreply,
     update_process_by_port(state, port, fn process ->
       handle_process_output(process, data)
     end)}
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    state =
      state
      |> update_process_by_port(port, &exit_process(&1, status, "exited"))
      |> refresh_run_states()

    {:noreply, state}
  end

  def handle_info({:process_timeout, run_id, process_id}, state) do
    state =
      state
      |> update_process(run_id, process_id, fn
        %{state: state_name} = process when state_name in @terminal_process_states ->
          process

        process ->
          terminate_process(process)
          exit_process(process, nil, "timed_out")
      end)
      |> refresh_run_states()

    {:noreply, state}
  end

  def handle_info({:ready_delay, run_id, process_id}, state) do
    {:noreply, mark_process_ready(state, run_id, process_id)}
  end

  def handle_info({:ready_tcp_check, run_id, process_id}, state) do
    {:noreply, mark_tcp_process_ready(state, run_id, process_id)}
  end

  defp create_run_state(state, body) do
    with {:ok, run_id} <- fetch_safe_run_id(body),
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
      {{:ok, 201, public_run(run)}, state}
    else
      true -> {{:error, 409, "run_exists"}, state}
      {:error, reason} -> {{:error, 422, reason}, state}
    end
  end

  defp executable?(path), do: System.find_executable(path) == path

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

  defp start_process_state(config, run, body) do
    with {:ok, role} <- fetch_allowed_role(body),
         {:ok, tool_name} <- fetch_string(body, "tool"),
         {:ok, tool} <- fetch_tool(config, tool_name),
         {:ok, argv} <- fetch_argv(body),
         {:ok, env} <- fetch_env(body),
         {:ok, timeout_ms} <- fetch_timeout(body),
         {:ok, ready} <- fetch_ready(body),
         {:ok, artifacts} <- fetch_artifacts(body) do
      prepare_artifact_dirs!(run.run_dir, artifacts)

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
        env: env,
        ready: ready,
        ready_buffer: "",
        artifacts: artifacts,
        state: initial_process_state(ready),
        exit_status: nil,
        port: nil,
        os_pid: nil,
        timeout_ref: nil,
        process_dir: process_dir,
        stdout_path: stdout_path,
        stderr_path: stderr_path
      }

      command = public_process(process) |> Map.put("command", [tool["path"] | argv])
      write_json!(Path.join(process_dir, "command.json"), command)

      port =
        Port.open(
          {:spawn_executable, tool["path"]},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, argv}
          ] ++ port_env_options(env)
        )

      os_pid = os_pid(port)

      timeout_ref =
        if timeout_ms do
          Process.send_after(self(), {:process_timeout, run.run_id, process_id}, timeout_ms)
        end

      schedule_ready_check(run.run_id, process_id, ready)

      process = %{process | port: port, os_pid: os_pid, timeout_ref: timeout_ref}
      run = put_in(run.processes[process_id], process)
      {:ok, process, run}
    end
  end

  defp initial_process_state(%{"type" => "none"}), do: "running"
  defp initial_process_state(_ready), do: "starting"

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
      {:ok, %{"path" => path} = tool} ->
        if executable?(path) do
          {:ok, tool}
        else
          {:error, "tool_not_executable"}
        end

      :error ->
        {:error, "unknown_tool"}
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

  defp fetch_env(body) do
    env = Map.get(body, "env", %{})

    cond do
      !is_map(env) ->
        {:error, "invalid_env"}

      Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end) ->
        {:ok, env}

      true ->
        {:error, "invalid_env"}
    end
  end

  defp fetch_timeout(body) do
    case Map.get(body, "timeout_ms") do
      nil -> {:ok, nil}
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      _other -> {:error, "invalid_timeout_ms"}
    end
  end

  defp fetch_ready(body) do
    case Map.get(body, "ready", %{"type" => "none"}) do
      nil ->
        {:ok, %{"type" => "none"}}

      %{"type" => "none"} ->
        {:ok, %{"type" => "none"}}

      %{"type" => "stdout_contains", "text" => text} when is_binary(text) and text != "" ->
        {:ok, %{"type" => "stdout_contains", "text" => text}}

      %{"type" => "udp_port", "port" => port} = ready ->
        fetch_port_ready(ready, port)

      %{"type" => "tcp_port", "port" => port} = ready ->
        fetch_port_ready(ready, port)

      _other ->
        {:error, "invalid_ready"}
    end
  end

  defp fetch_port_ready(ready, port) when is_integer(port) and port > 0 and port <= 65_535 do
    with {:ok, startup_delay_ms} <- fetch_startup_delay(ready) do
      {:ok,
       %{
         "type" => ready["type"],
         "port" => port,
         "startup_delay_ms" => startup_delay_ms
       }}
    end
  end

  defp fetch_port_ready(_ready, _port), do: {:error, "invalid_ready"}

  defp fetch_startup_delay(ready) do
    case Map.get(ready, "startup_delay_ms", 100) do
      delay when is_integer(delay) and delay >= 0 -> {:ok, delay}
      _invalid -> {:error, "invalid_ready"}
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

  defp prepare_artifact_dirs!(run_dir, artifacts) do
    Enum.each(artifacts, fn {_name, artifact_path} ->
      [run_dir, "artifacts", artifact_path]
      |> Path.join()
      |> Path.dirname()
      |> File.mkdir_p!()
    end)
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
      "env" => process.env,
      "ready" => process.ready,
      "state" => process.state,
      "exit_status" => process.exit_status,
      "artifacts" => process.artifacts
    }
  end

  defp handle_process_output(process, data) do
    File.write!(process.stdout_path, data, [:append])

    process
    |> append_ready_buffer(data)
    |> mark_ready_if_matched()
  end

  defp append_ready_buffer(process, data) do
    ready_buffer =
      process.ready_buffer
      |> Kernel.<>(data)
      |> tail_bytes(8192)

    %{process | ready_buffer: ready_buffer}
  end

  defp tail_bytes(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp tail_bytes(binary, max_bytes) do
    offset = byte_size(binary) - max_bytes
    binary_part(binary, offset, max_bytes)
  end

  defp mark_ready_if_matched(
         %{state: "starting", ready: %{"type" => "stdout_contains", "text" => text}} = process
       ) do
    if String.contains?(process.ready_buffer, text) do
      %{process | state: "ready"}
    else
      process
    end
  end

  defp mark_ready_if_matched(process), do: process

  defp schedule_ready_check(run_id, process_id, %{
         "type" => "udp_port",
         "startup_delay_ms" => startup_delay_ms
       }) do
    Process.send_after(self(), {:ready_delay, run_id, process_id}, startup_delay_ms)
  end

  defp schedule_ready_check(run_id, process_id, %{
         "type" => "tcp_port",
         "startup_delay_ms" => startup_delay_ms
       }) do
    Process.send_after(self(), {:ready_tcp_check, run_id, process_id}, startup_delay_ms)
  end

  defp schedule_ready_check(_run_id, _process_id, _ready), do: nil

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

  defp mark_process_ready(state, run_id, process_id) do
    update_process(state, run_id, process_id, fn
      %{state: "starting"} = process -> %{process | state: "ready"}
      process -> process
    end)
  end

  defp mark_tcp_process_ready(state, run_id, process_id) do
    case fetch_process(state, run_id, process_id) do
      {:ok, %{state: "starting", ready: %{"port" => port}}} ->
        mark_if_tcp_ready(state, run_id, process_id, port)

      _not_starting ->
        state
    end
  end

  defp mark_if_tcp_ready(state, run_id, process_id, port) do
    if tcp_port_ready?(port) do
      mark_process_ready(state, run_id, process_id)
    else
      Process.send_after(self(), {:ready_tcp_check, run_id, process_id}, 50)
      state
    end
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

  defp port_env_options(env) when map_size(env) == 0, do: []

  defp port_env_options(env) do
    [{:env, Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)}]
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _unknown -> nil
    end
  end

  defp terminate_process(%{os_pid: os_pid}) when is_integer(os_pid) do
    System.cmd("pkill", ["-TERM", "-P", Integer.to_string(os_pid)], stderr_to_stdout: true)
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp terminate_process(%{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  defp terminate_process(_process), do: :ok

  defp tcp_port_ready?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 50) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp ensure_no_running_processes(run) do
    if Enum.any?(run.processes, fn {_id, process} -> process.state in @active_process_states end) do
      {:error, "run_has_active_processes"}
    else
      :ok
    end
  end

  defp refresh_run_states(state) do
    update_in(state.runs, fn runs ->
      Map.new(runs, fn {run_id, run} -> {run_id, refresh_run_state(run)} end)
    end)
  end

  defp refresh_run_state(%{state: "cleaned"} = run), do: run

  defp refresh_run_state(run) do
    processes = Map.values(run.processes)

    cond do
      processes == [] ->
        run

      Enum.any?(processes, &(&1.state in @active_process_states)) ->
        %{run | state: "active"}

      Enum.all?(processes, &(&1.state in @terminal_process_states)) ->
        %{run | state: terminal_run_state(processes)}

      true ->
        run
    end
  end

  defp terminal_run_state(processes) do
    if Enum.all?(processes, &(&1.state == "exited" and &1.exit_status == 0)) do
      "complete"
    else
      "aborted"
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
end
