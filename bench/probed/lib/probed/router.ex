defmodule Probed.Router do
  @moduledoc false

  use Plug.Router

  alias Probed.Runner

  import Plug.Conn

  plug(:match)
  plug(:authenticate)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:dispatch)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    conn
    |> put_private(:probed_runner, Keyword.get(opts, :runner, Runner))
    |> super(opts)
  end

  get "/v1/health" do
    conn
    |> runner()
    |> Runner.health()
    |> json_result(conn)
  end

  get "/v1/node" do
    conn
    |> runner()
    |> Runner.node()
    |> json_result(conn)
  end

  get "/v1/tools" do
    conn
    |> runner()
    |> Runner.tools()
    |> json_result(conn)
  end

  post "/v1/runs" do
    conn
    |> runner()
    |> Runner.create_run(conn.body_params)
    |> json_result(conn)
  end

  get "/v1/runs/:run_id" do
    conn
    |> runner()
    |> Runner.run(run_id)
    |> json_result(conn)
  end

  delete "/v1/runs/:run_id" do
    conn
    |> runner()
    |> Runner.delete_run(run_id)
    |> json_result(conn)
  end

  post "/v1/runs/:run_id/processes" do
    conn
    |> runner()
    |> Runner.start_process(run_id, conn.body_params)
    |> json_result(conn)
  end

  get "/v1/runs/:run_id/processes" do
    conn
    |> runner()
    |> Runner.processes(run_id)
    |> json_result(conn)
  end

  get "/v1/runs/:run_id/processes/:process_id" do
    conn
    |> runner()
    |> Runner.process(run_id, process_id)
    |> json_result(conn)
  end

  delete "/v1/runs/:run_id/processes/:process_id" do
    conn
    |> runner()
    |> Runner.stop_process(run_id, process_id)
    |> json_result(conn)
  end

  get "/v1/runs/:run_id/artifacts" do
    conn
    |> runner()
    |> Runner.artifacts(run_id)
    |> json_result(conn)
  end

  get "/v1/runs/:run_id/artifacts/*artifact_parts" do
    conn
    |> runner()
    |> Runner.artifact(run_id, artifact_parts)
    |> file_result(conn)
  end

  get "/v1/runs/:run_id/bundle" do
    conn
    |> runner()
    |> Runner.bundle(run_id)
    |> file_result(conn)
  end

  match _ do
    json(conn, 404, %{"error" => "not_found"})
  end

  defp authenticate(conn, _opts) do
    token = Runner.token(runner(conn))

    case get_req_header(conn, "authorization") do
      ["Bearer " <> ^token] -> conn
      _other -> conn |> json(401, %{"error" => "unauthorized"}) |> halt()
    end
  end

  defp runner(conn), do: conn.private[:probed_runner]

  defp json_result({:ok, body}, conn), do: json(conn, 200, body)
  defp json_result({:ok, status, body}, conn), do: json(conn, status, body)
  defp json_result({:error, status, reason}, conn), do: json(conn, status, %{"error" => reason})

  defp file_result({:file, body, content_type}, conn) do
    conn
    |> put_resp_content_type(content_type)
    |> send_resp(200, body)
  end

  defp file_result({:error, status, reason}, conn), do: json(conn, status, %{"error" => reason})

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
