defmodule MOQX.TransportBench.PathMetadataTest do
  use ExUnit.Case, async: true

  alias MOQX.TransportBench.PathMetadata

  test "loads path metadata from an inline JSON object" do
    metadata =
      PathMetadata.load_json!("""
      {
        "evidence_tier": "cross_region_pair",
        "path_id": "inline-path",
        "client": {"host_id": "client"},
        "server": {"host_id": "server"}
      }
      """)

    assert metadata["path_id"] == "inline-path"
    assert metadata["client"]["host_id"] == "client"
    assert metadata["server"]["host_id"] == "server"
  end

  test "loads path metadata from a JSON file" do
    path = tmp_path("path-metadata.json")

    File.write!(path, ~s({"path_id":"file-path","client":{},"server":{}}))
    on_exit(fn -> File.rm(path) end)

    assert PathMetadata.load_json!(path)["path_id"] == "file-path"
  end

  test "unwraps Terraform output and path wrappers" do
    metadata =
      PathMetadata.load_json!("""
      {
        "value": {
          "path": {
            "path_id": "terraform-path",
            "client": {},
            "server": {}
          }
        }
      }
      """)

    assert metadata["path_id"] == "terraform-path"
  end

  defp tmp_path(name) do
    Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
  end
end
