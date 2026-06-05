defmodule Probed.HTTPAPITest do
  use ExUnit.Case, async: true

  test "requires bearer auth and reports health" do
    {:ok, server} =
      Probed.HTTPServer.start_link(
        config: %{
          node_id: "test-node",
          bind: "127.0.0.1:0",
          work_dir: tmp_dir(),
          token: "secret-token",
          tools: %{}
        }
      )

    port = Probed.HTTPServer.port(server)

    assert {401, _headers, body} = request(port, "GET", "/v1/health", nil, token: nil)
    assert %{"error" => "unauthorized"} = Jason.decode!(body)

    assert {200, _headers, body} = request(port, "GET", "/v1/health", nil)

    assert %{
             "status" => "ok",
             "node_id" => "test-node",
             "version" => "0.1.0"
           } = Jason.decode!(body)
  end

  test "reports node metadata and configured tool status" do
    dir = tmp_dir()
    tool_path = fake_tool!(dir, "fake-tool")

    {:ok, server} =
      Probed.HTTPServer.start_link(
        config: %{
          node_id: "tool-node",
          bind: "127.0.0.1:0",
          work_dir: dir,
          token: "secret-token",
          tools: %{
            "fake" => %{"path" => tool_path},
            "missing" => %{"path" => Path.join(dir, "missing-tool")}
          }
        }
      )

    port = Probed.HTTPServer.port(server)

    assert {200, _headers, body} = request(port, "GET", "/v1/node", nil)

    assert %{
             "node_id" => "tool-node",
             "work_dir" => ^dir
           } = Jason.decode!(body)

    assert {200, _headers, body} = request(port, "GET", "/v1/tools", nil)

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

    {:ok, server} =
      Probed.HTTPServer.start_link(
        config: %{
          node_id: "runner-node",
          bind: "127.0.0.1:0",
          work_dir: dir,
          token: "secret-token",
          tools: %{"artifact" => %{"path" => tool_path}}
        }
      )

    port = Probed.HTTPServer.port(server)

    assert {201, _headers, body} =
             request(
               port,
               "POST",
               "/v1/runs",
               Jason.encode!(%{"run_id" => run_id, "metadata" => %{"purpose" => "test"}})
             )

    assert %{"run_id" => ^run_id, "state" => "active"} = Jason.decode!(body)

    assert {201, _headers, body} =
             request(
               port,
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
             wait_for_process(port, run_id, process_id)

    assert {200, _headers, body} = request(port, "GET", "/v1/runs/#{run_id}/artifacts", nil)

    assert %{"artifacts" => artifacts} = Jason.decode!(body)
    assert "artifacts/client/result.jsonl" in artifacts
    assert "processes/#{process_id}/stdout.log" in artifacts
    assert "processes/#{process_id}/stderr.log" in artifacts

    assert {200, _headers, body} =
             request(
               port,
               "GET",
               "/v1/runs/#{run_id}/artifacts/artifacts/client/result.jsonl",
               nil
             )

    assert body == "{\"ok\":true}\n"

    assert {200, headers, bundle} = request(port, "GET", "/v1/runs/#{run_id}/bundle", nil)
    assert headers["content-type"] == "application/gzip"
    assert byte_size(bundle) > 0
  end

  defp request(port, method, path, body, opts \\ []) do
    token = Keyword.get(opts, :token, "secret-token")
    body = body || ""

    auth =
      case token do
        nil -> ""
        token -> "Authorization: Bearer #{token}\r\n"
      end

    request = """
    #{method} #{path} HTTP/1.1\r
    Host: 127.0.0.1:#{port}\r
    #{auth}Content-Type: application/json\r
    Content-Length: #{byte_size(body)}\r
    \r
    #{body}\
    """

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = recv_all(socket, "")
    :ok = :gen_tcp.close(socket)
    parse_response(response)
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> {:ok, acc}
    end
  end

  defp parse_response(response) do
    [status_line | rest] = String.split(response, "\r\n")
    ["HTTP/1.1", status, _reason] = String.split(status_line, " ", parts: 3)
    [header_lines, body] = rest |> Enum.join("\r\n") |> String.split("\r\n\r\n", parts: 2)

    headers =
      header_lines
      |> String.split("\r\n", trim: true)
      |> Map.new(fn line ->
        [key, value] = String.split(line, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    {String.to_integer(status), headers, body}
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
    mkdir -p "$(dirname "$1")"
    printf '{"ok":true}\\n' > "$1"
    printf 'tool stdout\\n'
    printf 'tool stderr\\n' >&2
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp wait_for_process(port, run_id, process_id) do
    Enum.reduce_while(1..50, nil, fn _attempt, _acc ->
      assert {200, _headers, body} =
               request(port, "GET", "/v1/runs/#{run_id}/processes/#{process_id}", nil)

      process = Jason.decode!(body)

      case process["state"] do
        "exited" -> {:halt, process}
        _state -> Process.sleep(20) && {:cont, process}
      end
    end)
  end
end
