defmodule MOQXProbe.Benchee.RunMetadata do
  @moduledoc false

  @spec git_sha(keyword()) :: String.t()
  def git_sha(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: cwd, stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      {_output, _status} -> "unknown"
    end
  rescue
    _error -> "unknown"
  end

  @doc """
  Project/tool versions for the run manifest (ADR-0009). Unknown app versions
  are reported as `nil` rather than omitted.
  """
  @spec versions() :: %{
          moqx: String.t() | nil,
          moqxprobe: String.t() | nil,
          elixir: String.t(),
          otp: String.t()
        }
  def versions do
    %{
      moqx: :moqx |> Application.spec(:vsn) |> version_string(),
      moqxprobe: :moqxprobe |> Application.spec(:vsn) |> version_string(),
      elixir: System.version(),
      otp: System.otp_release()
    }
  end

  defp version_string(nil), do: nil
  defp version_string(vsn), do: List.to_string(vsn)

  @spec iperf3_summaries([Path.t()] | nil) :: [map()]
  def iperf3_summaries(nil), do: []

  def iperf3_summaries(paths) when is_list(paths) do
    Enum.map(paths, &iperf3_summary/1)
  end

  @spec iperf3_summary(Path.t()) :: map()
  def iperf3_summary(path) when is_binary(path) do
    case File.read(path) do
      {:ok, body} ->
        decode_iperf3(path, body)

      {:error, reason} ->
        %{path: path, status: :error, error: inspect(reason)}
    end
  end

  defp decode_iperf3(path, body) do
    body
    |> JSON.decode!()
    |> compact_iperf3(path)
  rescue
    error -> %{path: path, status: :error, error: Exception.message(error)}
  end

  defp compact_iperf3(decoded, path) when is_map(decoded) do
    end_summary = Map.get(decoded, "end", %{})
    protocol = decoded |> get_in(["start", "test_start", "protocol"]) |> normalize_protocol()
    sum = Map.get(end_summary, "sum")

    cond do
      protocol == "udp" ->
        udp_summary(path, end_summary)

      protocol == "tcp" and is_map(Map.get(end_summary, "sum_received")) ->
        tcp_summary(path, end_summary)

      udp_summary?(sum) ->
        udp_summary(path, end_summary)

      is_map(Map.get(end_summary, "sum_received")) ->
        tcp_summary(path, end_summary)

      is_map(sum) ->
        udp_summary(path, end_summary)

      true ->
        %{path: path, status: :ok, protocol: Map.get(decoded, "protocol", "unknown")}
    end
  end

  defp compact_iperf3(_decoded, path) do
    %{path: path, status: :error, error: "iperf3 JSON root is not an object"}
  end

  defp normalize_protocol(protocol) when is_binary(protocol), do: protocol |> String.downcase()
  defp normalize_protocol(_protocol), do: nil

  defp udp_summary?(summary) when is_map(summary) do
    Map.has_key?(summary, "jitter_ms") or Map.has_key?(summary, "lost_percent")
  end

  defp udp_summary?(_summary), do: false

  defp tcp_summary(path, end_summary) do
    sum_received = Map.fetch!(end_summary, "sum_received")
    sum_sent = Map.get(end_summary, "sum_sent", %{})

    %{
      path: path,
      status: :ok,
      protocol: "tcp",
      bits_per_second: Map.get(sum_received, "bits_per_second"),
      bytes: Map.get(sum_received, "bytes"),
      retransmits: Map.get(sum_sent, "retransmits")
    }
  end

  defp udp_summary(path, end_summary) do
    sum = Map.get(end_summary, "sum_received") || Map.fetch!(end_summary, "sum")

    %{
      path: path,
      status: :ok,
      protocol: "udp",
      bits_per_second: Map.get(sum, "bits_per_second"),
      bytes: Map.get(sum, "bytes"),
      jitter_ms: Map.get(sum, "jitter_ms"),
      lost_percent: Map.get(sum, "lost_percent"),
      lost_packets: Map.get(sum, "lost_packets"),
      packets: Map.get(sum, "packets")
    }
  end
end
