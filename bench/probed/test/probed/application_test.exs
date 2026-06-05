defmodule Probed.ApplicationTest do
  use ExUnit.Case, async: true

  test "builds runner and Bandit children from config file env" do
    dir = tmp_dir()
    config_path = Path.join(dir, "probed.json")

    File.write!(
      config_path,
      Jason.encode!(%{
        "node_id" => "daemon-node",
        "bind" => "127.0.0.1:0",
        "work_dir" => Path.join(dir, "work"),
        "token" => "secret-token",
        "tools" => %{}
      })
    )

    assert [
             {Probed.Runner,
              [
                name: Probed.Runner,
                config: %Probed.Config{
                  node_id: "daemon-node",
                  bind_host: "127.0.0.1",
                  bind_port: 0,
                  token: "secret-token"
                }
              ]},
             {Bandit,
              [
                plug: {Probed.Router, [runner: Probed.Runner]},
                ip: {127, 0, 0, 1},
                port: 0,
                startup_log: false
              ]}
           ] = Probed.Application.children(env: %{"PROBED_CONFIG" => config_path})
  end

  test "does not start a daemon when no config exists" do
    missing_config = Path.join(tmp_dir(), "missing-probed.json")

    assert [] =
             Probed.Application.children(
               env: %{},
               default_path: missing_config
             )
  end

  test "Bandit child serves the router over HTTP" do
    dir = tmp_dir()

    runner =
      start_supervised!(
        {Probed.Runner,
         config: %{
           node_id: "bandit-node",
           bind: "127.0.0.1:0",
           work_dir: dir,
           token: "secret-token",
           tools: %{}
         }}
      )

    bandit =
      start_supervised!(
        {Bandit,
         plug: {Probed.Router, runner: runner}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    {:ok, _started} = Application.ensure_all_started(:inets)

    assert {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, _headers, body}} =
             :httpc.request(
               :get,
               {
                 ~c"http://127.0.0.1:#{port}/v1/health",
                 [{~c"Authorization", ~c"Bearer secret-token"}]
               },
               [],
               body_format: :binary
             )

    assert %{"status" => "ok", "node_id" => "bandit-node"} = Jason.decode!(body)
  end

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "probed-application-test-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
