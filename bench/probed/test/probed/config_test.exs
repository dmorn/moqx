defmodule Probed.ConfigTest do
  use ExUnit.Case, async: true

  alias Probed.Config

  test "loads json config with token file and explicit env overrides" do
    dir = tmp_dir()
    config_path = Path.join(dir, "probed.json")
    token_path = Path.join(dir, "probed.token")
    work_dir = Path.join(dir, "work")
    override_work_dir = Path.join(dir, "override-work")
    tool_path = Path.join(dir, "bin/tool")

    File.mkdir_p!(Path.dirname(tool_path))
    File.write!(token_path, "file-token\n")

    File.write!(
      config_path,
      Jason.encode!(%{
        "node_id" => "config-node",
        "bind" => "10.88.0.11:9157",
        "work_dir" => work_dir,
        "token_file" => token_path,
        "tools" => %{
          "fake" => %{"path" => tool_path}
        }
      })
    )

    config =
      Config.load!(
        env: %{
          "PROBED_CONFIG" => config_path,
          "PROBED_BIND" => "127.0.0.1:0",
          "PROBED_TOKEN" => "env-token",
          "PROBED_WORK_DIR" => override_work_dir,
          "PROBED_NODE_ID" => "env-node"
        }
      )

    assert %Config{
             node_id: "env-node",
             bind_host: "127.0.0.1",
             bind_port: 0,
             work_dir: ^override_work_dir,
             token: "env-token",
             tools: %{"fake" => %{"path" => ^tool_path}}
           } = config
  end

  test "rejects configured tools without absolute paths" do
    assert_raise ArgumentError, ~r/path must be absolute/, fn ->
      Config.from_map!(%{
        "node_id" => "node",
        "bind" => "127.0.0.1:0",
        "work_dir" => "/tmp/probed-test",
        "token" => "secret-token",
        "tools" => %{"fake" => %{"path" => "relative-tool"}}
      })
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "probed-config-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
