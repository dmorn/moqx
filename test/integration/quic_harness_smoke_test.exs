defmodule MOQX.Integration.QuicHarnessSmokeTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  test "integration tag can be selected explicitly without starting Docker from ExUnit" do
    assert {:ok, integration} = Application.fetch_env(:moqx, :integration)
    assert Keyword.has_key?(integration, :quic_ref_server)
    assert Keyword.has_key?(integration, :probe_cli)
  end
end
