defmodule MOQXProbe.Benchee.RunMetadataTest do
  use ExUnit.Case, async: true

  alias MOQXProbe.Benchee.RunMetadata

  test "summarizes TCP iperf3 JSON" do
    path =
      write_json!(%{
        end: %{
          sum_received: %{bits_per_second: 12_000_000.0, bytes: 1_500_000},
          sum_sent: %{retransmits: 2}
        }
      })

    assert [
             %{
               path: ^path,
               status: :ok,
               protocol: "tcp",
               bits_per_second: 12_000_000.0,
               bytes: 1_500_000,
               retransmits: 2
             }
           ] = RunMetadata.iperf3_summaries([path])
  end

  test "summarizes UDP iperf3 JSON" do
    path =
      write_json!(%{
        end: %{
          sum: %{
            bits_per_second: 5_000_000.0,
            bytes: 625_000,
            jitter_ms: 1.25,
            lost_percent: 0.1
          }
        }
      })

    assert [
             %{
               path: ^path,
               status: :ok,
               protocol: "udp",
               bits_per_second: 5_000_000.0,
               bytes: 625_000,
               jitter_ms: 1.25,
               lost_percent: 0.1
             }
           ] = RunMetadata.iperf3_summaries([path])
  end

  test "records unreadable iperf3 summary errors as metadata" do
    path = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}.json")

    assert [%{path: ^path, status: :error, error: error}] = RunMetadata.iperf3_summaries([path])
    assert error =~ "enoent"
  end

  defp write_json!(term) do
    path = Path.join(System.tmp_dir!(), "iperf3-#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode!(term))
    path
  end
end
