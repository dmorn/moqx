defmodule MOQXProbe.Benchee.Adapters.Quicprobe do
  @moduledoc false

  @behaviour MOQXProbe.Benchee.EvidenceAdapter

  alias MOQXProbe.Benchee.Evidence
  alias MOQXProbe.Benchee.RunReceipt

  @counter_fields [
    "datagrams_received",
    "datagrams_echo_accepted",
    "datagram_bytes_received",
    "datagram_bytes_echo_accepted",
    "bidi_streams_accepted",
    "uni_streams_accepted",
    "streams_completed",
    "stream_bytes_received",
    "stream_bytes_echo_accepted",
    "stream_receive_error_count",
    "stream_send_error_count",
    "receiver_evidence_complete"
  ]

  @impl true
  def collect(%RunReceipt{} = receipt, opts) do
    case evidence_source(opts) do
      {:ok, source} ->
        timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
        poll_ms = Keyword.get(opts, :poll_ms, 50)
        deadline = System.monotonic_time(:millisecond) + timeout_ms

        poll_for_evidence(receipt, source, deadline, poll_ms, timeout_ms)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec last_run_sequence(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def last_run_sequence(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} ->
        last_run_sequence_from_content(content)

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def last_run_sequence(opts) when is_list(opts) do
    case evidence_source(opts) do
      {:ok, {:path, path}} -> last_run_sequence(path)
      {:ok, {:url, url}} -> last_run_sequence_from_url(url, Keyword.get(opts, :timeout_ms, 5_000))
      {:error, reason} -> {:error, reason}
    end
  end

  defp evidence_source(opts) do
    case {Keyword.fetch(opts, :url), Keyword.fetch(opts, :path)} do
      {{:ok, url}, _path} -> {:ok, {:url, url}}
      {:error, {:ok, path}} -> {:ok, {:path, path}}
      {:error, :error} -> {:error, :missing_quicprobe_evidence_source}
    end
  end

  defp last_run_sequence_from_content(content) do
    with {:ok, records} <- decode_jsonl(content) do
      {:ok, last_run_sequence_from_records(records)}
    end
  end

  defp last_run_sequence_from_records(records) do
    records
    |> Enum.filter(&server_run_evidence?/1)
    |> Enum.map(&Map.get(&1, "run_sequence", 0))
    |> Enum.max(fn -> 0 end)
  end

  defp last_run_sequence_from_url(url, timeout_ms) do
    case get_api_json(url, "/evidence/latest", timeout_ms) do
      {:ok, response} -> {:ok, Map.get(response, "latest_run_sequence", 0)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp poll_for_evidence(receipt, source, deadline, poll_ms, timeout_ms) do
    case read_matching_evidence(source, receipt, timeout_ms) do
      {:ok, record} ->
        {:ok, record_to_evidence(receipt, source, record)}

      :not_found ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:ok,
           Evidence.timeout(receipt, :quicprobe, timeout_ms, metadata: source_metadata(source))}
        else
          Process.sleep(poll_ms)
          poll_for_evidence(receipt, source, deadline, poll_ms, timeout_ms)
        end

      {:error, reason} ->
        {:ok, Evidence.error(receipt, :quicprobe, reason, metadata: source_metadata(source))}
    end
  end

  defp read_matching_evidence({:path, path}, receipt, _timeout_ms) do
    with {:ok, content} <- File.read(path),
         {:ok, records} <- decode_jsonl(content) do
      select_matching_evidence(records, receipt)
    else
      {:error, :enoent} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_matching_evidence({:url, url}, receipt, timeout_ms) do
    path =
      "/evidence/runs?" <> URI.encode_query(%{"after_sequence" => after_run_sequence(receipt)})

    with {:ok, response} <- get_api_json(url, path, timeout_ms) do
      response
      |> Map.get("runs", [])
      |> select_matching_evidence(receipt)
    end
  end

  defp select_matching_evidence(records, receipt) do
    records
    |> Enum.filter(&(server_run_evidence?(&1) and matches_receipt?(&1, receipt)))
    |> select_match(receipt)
    |> case do
      nil -> :not_found
      record -> {:ok, record}
    end
  end

  defp decode_jsonl(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, records} ->
      try do
        {:cont, {:ok, [JSON.decode!(line) | records]}}
      rescue
        reason -> {:halt, {:error, {:invalid_jsonl, reason}}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp server_run_evidence?(record) do
    Map.get(record, "record_type") == "server_run_evidence"
  end

  defp matches_receipt?(record, %RunReceipt{match: match}) when map_size(match) == 0 do
    Map.get(record, "record_type") == "server_run_evidence"
  end

  defp matches_receipt?(record, %RunReceipt{match: match}) do
    exact_match =
      match
      |> Map.delete(:after_run_sequence)
      |> Map.delete("after_run_sequence")

    Map.get(record, "run_sequence", 0) > after_run_sequence(match) and
      Enum.all?(exact_match, fn {key, value} -> Map.get(record, to_string(key)) == value end)
  end

  defp after_run_sequence(%RunReceipt{match: match}), do: after_run_sequence(match)

  defp after_run_sequence(match) do
    Map.get(match, :after_run_sequence, Map.get(match, "after_run_sequence", 0))
  end

  defp select_match(records, %RunReceipt{match: match}) do
    if has_after_run_sequence?(match) do
      List.first(records)
    else
      List.last(records)
    end
  end

  defp has_after_run_sequence?(match),
    do: Map.has_key?(match, :after_run_sequence) or Map.has_key?(match, "after_run_sequence")

  defp record_to_evidence(receipt, source, record) do
    complete? = Map.get(record, "receiver_evidence_complete", true)
    error = Map.get(record, "receiver_evidence_failure_cause")

    Evidence.from_observed(receipt, observed_counters(record),
      source: :quicprobe,
      complete?: complete?,
      error: error,
      metadata: Map.put(source_metadata(source), :raw, record)
    )
  end

  defp observed_counters(record) do
    Map.new(@counter_fields, fn field -> {String.to_atom(field), Map.get(record, field)} end)
  end

  defp source_metadata({:path, path}), do: %{path: path}
  defp source_metadata({:url, url}), do: %{url: url}

  defp get_api_json(base_url, path, timeout_ms) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    url = base_url |> String.trim_trailing("/") |> Kernel.<>(path)

    request = {String.to_charlist(url), []}
    http_options = [{:timeout, timeout_ms}]
    options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        decode_api_json(body)

      {:ok, {{_version, status, reason}, _headers, body}} ->
        {:error, {:http_error, status, to_string(reason), body}}

      {:error, reason} ->
        {:error, {:http_request_failed, reason}}
    end
  end

  defp decode_api_json(body) do
    {:ok, JSON.decode!(body)}
  rescue
    reason -> {:error, {:invalid_json, reason}}
  end
end
