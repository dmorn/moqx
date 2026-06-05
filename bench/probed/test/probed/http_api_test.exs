defmodule Probed.HTTPAPITest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  test "requires bearer auth and reports health" do
    runner =
      start_runner!(
        node_id: "test-node",
        bind: "127.0.0.1:0",
        work_dir: tmp_dir(),
        token: "secret-token",
        tools: %{}
      )

    assert {401, _headers, body} = request(runner, "GET", "/v1/health", nil, token: nil)
    assert %{"error" => "unauthorized"} = Jason.decode!(body)

    assert {200, _headers, body} = request(runner, "GET", "/v1/health", nil)

    assert %{
             "status" => "ok",
             "node_id" => "test-node",
             "version" => "0.1.0"
           } = Jason.decode!(body)
  end

  test "reports node metadata and configured tool status" do
    dir = tmp_dir()
    tool_path = fake_tool!(dir, "fake-tool")

    runner =
      start_runner!(
        node_id: "tool-node",
        bind: "127.0.0.1:0",
        work_dir: dir,
        token: "secret-token",
        tools: %{
          "fake" => %{"path" => tool_path},
          "missing" => %{"path" => Path.join(dir, "missing-tool")}
        }
      )

    assert {200, _headers, body} = request(runner, "GET", "/v1/node", nil)

    assert %{
             "node_id" => "tool-node",
             "work_dir" => ^dir
           } = Jason.decode!(body)

    assert {200, _headers, body} = request(runner, "GET", "/v1/tools", nil)

    assert %{
             "tools" => %{
               "fake" => %{"path" => ^tool_path, "exists" => true, "executable" => true},
               "missing" => %{"exists" => false, "executable" => false}
             }
           } = Jason.decode!(body)
  end

  test "runs a configured tool and exposes artifacts and bundle" do
    dir = tmp_dir()
    tool_path = artifact_tool!(dir, "artifact-tool")
    run_id = "run-1"
    artifact_rel = "artifacts/client/result.jsonl"
    artifact_path = Path.join([dir, "runs", run_id, artifact_rel])

    runner =
      start_runner!(
        node_id: "runner-node",
        bind: "127.0.0.1:0",
        work_dir: dir,
        token: "secret-token",
        tools: %{"artifact" => %{"path" => tool_path}}
      )

    assert {201, _headers, body} =
             request(
               runner,
               "POST",
               "/v1/runs",
               Jason.encode!(%{"run_id" => run_id, "metadata" => %{"purpose" => "test"}})
             )

    assert %{"run_id" => ^run_id, "state" => "active"} = Jason.decode!(body)

    assert {201, _headers, body} =
             request(
               runner,
               "POST",
               "/v1/runs/#{run_id}/processes",
               Jason.encode!(%{
                 "role" => "moqx_client",
                 "tool" => "artifact",
                 "argv" => [artifact_path],
                 "timeout_ms" => 5_000,
                 "artifacts" => %{"jsonl" => "client/result.jsonl"}
               })
             )

    assert %{"process_id" => process_id, "state" => state} = Jason.decode!(body)
    assert state in ["running", "exited"]

    assert %{"state" => "exited", "exit_status" => 0} =
             wait_for_process(runner, run_id, process_id)

    assert {200, _headers, body} = request(runner, "GET", "/v1/runs/#{run_id}", nil)
    assert %{"run_id" => ^run_id, "state" => "complete"} = Jason.decode!(body)

    assert {200, _headers, body} = request(runner, "GET", "/v1/runs/#{run_id}/artifacts", nil)

    assert %{"artifacts" => artifacts} = Jason.decode!(body)
    assert "artifacts/client/result.jsonl" in artifacts
    assert "processes/#{process_id}/stdout.log" in artifacts
    assert "processes/#{process_id}/stderr.log" in artifacts
    assert "processes/#{process_id}/exit.json" in artifacts

    assert {200, _headers, body} =
             request(
               runner,
               "GET",
               "/v1/runs/#{run_id}/artifacts/artifacts/client/result.jsonl",
               nil
             )

    assert body == "{\"ok\":true}\n"

    assert {200, headers, bundle} = request(runner, "GET", "/v1/runs/#{run_id}/bundle", nil)
    assert headers["content-type"] =~ "application/gzip"
    assert byte_size(bundle) > 0

    assert {200, _headers, stdout} =
             request(
               runner,
               "GET",
               "/v1/runs/#{run_id}/artifacts/processes/#{process_id}/stdout.log",
               nil
             )

    assert stdout =~ "tool stdout"

    assert {404, _headers, body} =
             request(runner, "GET", "/v1/runs/#{run_id}/artifacts/../outside.txt", nil)

    assert %{"error" => "invalid_path"} = Jason.decode!(body)

    assert {200, _headers, body} = request(runner, "DELETE", "/v1/runs/#{run_id}", nil)
    assert %{"run_id" => ^run_id, "state" => "cleaned"} = Jason.decode!(body)
    assert {404, _headers, _body} = request(runner, "GET", "/v1/runs/#{run_id}", nil)
  end

  test "marks a process ready from stdout and records env metadata" do
    dir = tmp_dir()
    tool_path = ready_tool!(dir, "ready-tool")
    run_id = "ready-run"

    runner =
      start_runner!(
        node_id: "ready-node",
        bind: "127.0.0.1:0",
        work_dir: dir,
        token: "secret-token",
        tools: %{"ready" => %{"path" => tool_path}}
      )

    assert {201, _headers, _body} =
             request(runner, "POST", "/v1/runs", Jason.encode!(%{"run_id" => run_id}))

    assert {201, _headers, body} =
             request(
               runner,
               "POST",
               "/v1/runs/#{run_id}/processes",
               Jason.encode!(%{
                 "role" => "reference_server",
                 "tool" => "ready",
                 "argv" => [],
                 "env" => %{"PROBED_READY_TEXT" => "ready-from-env"},
                 "ready" => %{"type" => "stdout_contains", "text" => "ready-from-env"},
                 "timeout_ms" => 5_000
               })
             )

    assert %{"process_id" => process_id, "state" => "starting"} = Jason.decode!(body)
    assert %{"state" => "ready"} = wait_for_process_state(runner, run_id, process_id, "ready")

    assert {200, _headers, command_json} =
             request(
               runner,
               "GET",
               "/v1/runs/#{run_id}/artifacts/processes/#{process_id}/command.json",
               nil
             )

    assert %{"env" => %{"PROBED_READY_TEXT" => "ready-from-env"}} = Jason.decode!(command_json)

    assert {409, _headers, body} = request(runner, "DELETE", "/v1/runs/#{run_id}", nil)
    assert %{"error" => "run_has_active_processes"} = Jason.decode!(body)

    assert {200, _headers, body} =
             request(runner, "DELETE", "/v1/runs/#{run_id}/processes/#{process_id}", nil)

    assert %{"state" => "stopping"} = Jason.decode!(body)
    assert %{"state" => "exited"} = wait_for_process_state(runner, run_id, process_id, "exited")

    assert {200, _headers, body} = request(runner, "DELETE", "/v1/runs/#{run_id}", nil)
    assert %{"run_id" => ^run_id, "state" => "cleaned"} = Jason.decode!(body)

    assert {404, _headers, body} = request(runner, "GET", "/v1/runs/#{run_id}", nil)
    assert %{"error" => "run_not_found"} = Jason.decode!(body)
  end

  test "rejects a configured tool that is not executable without crashing" do
    dir = tmp_dir()
    run_id = "bad-tool-run"

    runner =
      start_runner!(
        node_id: "bad-tool-node",
        bind: "127.0.0.1:0",
        work_dir: dir,
        token: "secret-token",
        tools: %{"missing" => %{"path" => Path.join(dir, "missing-tool")}}
      )

    assert {201, _headers, _body} =
             request(runner, "POST", "/v1/runs", Jason.encode!(%{"run_id" => run_id}))

    assert {422, _headers, body} =
             request(
               runner,
               "POST",
               "/v1/runs/#{run_id}/processes",
               Jason.encode!(%{
                 "role" => "moqx_client",
                 "tool" => "missing",
                 "argv" => []
               })
             )

    assert %{"error" => "tool_not_executable"} = Jason.decode!(body)
    assert {200, _headers, _body} = request(runner, "GET", "/v1/health", nil)
  end

  test "marks udp_port readiness ready after bounded startup delay" do
    dir = tmp_dir()
    tool_path = ready_tool!(dir, "udp-ready-tool")
    run_id = "udp-ready-run"

    runner =
      start_runner!(
        node_id: "udp-ready-node",
        bind: "127.0.0.1:0",
        work_dir: dir,
        token: "secret-token",
        tools: %{"ready" => %{"path" => tool_path}}
      )

    assert {201, _headers, _body} =
             request(runner, "POST", "/v1/runs", Jason.encode!(%{"run_id" => run_id}))

    assert {201, _headers, body} =
             request(
               runner,
               "POST",
               "/v1/runs/#{run_id}/processes",
               Jason.encode!(%{
                 "role" => "reference_server",
                 "tool" => "ready",
                 "argv" => [],
                 "ready" => %{
                   "type" => "udp_port",
                   "port" => 4433,
                   "startup_delay_ms" => 10
                 }
               })
             )

    assert %{"process_id" => process_id, "state" => "starting"} = Jason.decode!(body)
    assert %{"state" => "ready"} = wait_for_process_state(runner, run_id, process_id, "ready")

    assert {200, _headers, _body} =
             request(runner, "DELETE", "/v1/runs/#{run_id}/processes/#{process_id}", nil)
  end

  defp request(runner, method, path, body, opts \\ []) do
    token = Keyword.get(opts, :token, "secret-token")

    conn =
      method
      |> conn(path, body || "")
      |> maybe_put_json_content_type(body)
      |> maybe_put_auth_header(token)
      |> Probed.Router.call(Probed.Router.init(runner: runner))

    headers = Map.new(conn.resp_headers)
    {conn.status, headers, conn.resp_body}
  end

  defp maybe_put_json_content_type(conn, nil), do: conn

  defp maybe_put_json_content_type(conn, _body),
    do: put_req_header(conn, "content-type", "application/json")

  defp maybe_put_auth_header(conn, nil), do: conn

  defp maybe_put_auth_header(conn, token) do
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp start_runner!(config) do
    start_supervised!({Probed.Runner, config: Map.new(config)})
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "probed-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp fake_tool!(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\nprintf 'ok\\n'\n")
    File.chmod!(path, 0o755)
    path
  end

  defp artifact_tool!(dir, name) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    printf '{"ok":true}\\n' > "$1"
    printf 'tool stdout\\n'
    printf 'tool stderr\\n' >&2
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp ready_tool!(dir, name) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$PROBED_READY_TEXT"
    sleep 5
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp wait_for_process(runner, run_id, process_id) do
    wait_for_process_state(runner, run_id, process_id, "exited")
  end

  defp wait_for_process_state(runner, run_id, process_id, expected_state) do
    Enum.reduce_while(1..50, nil, fn _attempt, _acc ->
      assert {200, _headers, body} =
               request(runner, "GET", "/v1/runs/#{run_id}/processes/#{process_id}", nil)

      process = Jason.decode!(body)

      case process["state"] do
        ^expected_state -> {:halt, process}
        _state -> Process.sleep(20) && {:cont, process}
      end
    end)
  end
end
