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

  test "summarizes UDP iperf3 JSON with receiver-side sum_received" do
    path =
      write_json!(%{
        start: %{test_start: %{protocol: "UDP"}},
        end: %{
          sum: %{
            bits_per_second: 25_000_000.0,
            bytes: 15_625_000,
            jitter_ms: 0.5,
            lost_percent: 0.0
          },
          sum_received: %{
            bits_per_second: 24_000_000.0,
            bytes: 15_000_000,
            jitter_ms: 1.0,
            lost_percent: 0.2,
            lost_packets: 10,
            packets: 5_000
          },
          sum_sent: %{
            bits_per_second: 25_000_000.0,
            bytes: 15_625_000
          }
        }
      })

    assert [
             %{
               path: ^path,
               status: :ok,
               protocol: "udp",
               bits_per_second: 24_000_000.0,
               bytes: 15_000_000,
               jitter_ms: 1.0,
               lost_percent: 0.2,
               lost_packets: 10,
               packets: 5_000
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
