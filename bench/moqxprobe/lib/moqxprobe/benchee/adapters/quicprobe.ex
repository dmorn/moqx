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
    "datagram_semantics",
    "bidi_streams_accepted",
    "uni_streams_accepted",
    "streams_completed",
    "stream_bytes_received",
    "stream_bytes_echo_accepted",
    "stream_receive_error_count",
    "stream_send_error_count",
    "receiver_evidence_complete"
  ]

  # Receiver-evidence delivery-shape fields surfaced from the quicprobe
  # server-run record. These are lifecycle windows (first/last byte and
  # DATAGRAM offsets) plus the raw interval bins. They are additive: an older
  # quicprobe build omits them and the sidecar simply records nil. Bandwidth
  # derivation belongs to a later report slice, so nothing is divided here
  # (ADR-0009).
  @interval_timestamp_fields [
    "first_stream_byte_at_ms",
    "last_stream_byte_at_ms",
    "first_datagram_at_ms",
    "last_datagram_at_ms"
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

  @spec acquire_experiment_lease(keyword()) :: {:ok, map()} | {:error, term()}
  def acquire_experiment_lease(opts) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    with {:ok, url} <- lease_url(opts) do
      payload =
        %{
          owner: Keyword.fetch!(opts, :owner),
          ttl_ms: Keyword.get(opts, :ttl_ms),
          metadata: Keyword.get(opts, :metadata)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      case post_api_json(url, "/experiment/lease/acquire", payload, timeout_ms) do
        {:ok, %{"status" => "acquired", "lease" => lease}} ->
          {:ok, lease}

        {:error, {:http_error, 409, _reason, body}} ->
          {:error, {:quicprobe_experiment_lease_busy, decode_error_body(body)}}

        {:ok, response} ->
          {:error, {:unexpected_quicprobe_experiment_lease_response, response}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec release_experiment_lease(keyword(), map()) :: :ok | {:error, term()}
  def release_experiment_lease(opts, lease) when is_list(opts) and is_map(lease) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    with {:ok, url} <- lease_url(opts),
         {:ok, token} <- lease_token(lease) do
      case post_api_json(url, "/experiment/lease/release", %{token: token}, timeout_ms) do
        {:ok, %{"status" => "released"}} ->
          :ok

        {:error, {:http_error, 409, _reason, body}} ->
          {:error, {:quicprobe_experiment_lease_release_failed, decode_error_body(body)}}

        {:ok, response} ->
          {:error, {:unexpected_quicprobe_experiment_lease_response, response}}

        {:error, reason} ->
          {:error, reason}
      end
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

  defp lease_url(opts) do
    case Keyword.fetch(opts, :url) do
      {:ok, url} when is_binary(url) -> {:ok, url}
      _missing -> {:error, :missing_quicprobe_evidence_url}
    end
  end

  defp lease_token(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp lease_token(%{token: token}) when is_binary(token), do: {:ok, token}
  defp lease_token(_lease), do: {:error, :missing_quicprobe_experiment_lease_token}

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
    complete? = evidence_complete?(receipt, record)
    error = if complete?, do: nil, else: Map.get(record, "receiver_evidence_failure_cause")

    metadata =
      source
      |> source_metadata()
      |> Map.put(:raw, record)
      |> Map.put(:receiver_interval, receiver_interval(record))
      |> Map.put(:object_delivery, object_delivery(record))

    Evidence.from_observed(receipt, observed_counters(record),
      source: :quicprobe,
      complete?: complete?,
      error: error,
      metadata: metadata
    )
  end

  # Builds the explicit receiver-evidence interval view from a quicprobe
  # server-run record. Keeps raw counts per window (bytes/datagrams/events) and
  # makes the window width explicit; it never derives a rate. Returns nil when
  # the quicprobe build predates interval bins so the sidecar stays additive.
  defp receiver_interval(record) do
    bins = normalize_interval_bins(Map.get(record, "interval_bins"))

    if interval_evidence?(record, bins) do
      %{
        bin_width_ms: Map.get(record, "interval_bin_width_ms"),
        first_stream_byte_at_ms: Map.get(record, "first_stream_byte_at_ms"),
        last_stream_byte_at_ms: Map.get(record, "last_stream_byte_at_ms"),
        first_datagram_at_ms: Map.get(record, "first_datagram_at_ms"),
        last_datagram_at_ms: Map.get(record, "last_datagram_at_ms"),
        bins: bins
      }
    end
  end

  # A quicprobe build that emits interval evidence always carries a positive
  # interval_bin_width_ms (validated > 0 server-side), so that field is the
  # reliable additive sentinel: a zero-traffic new build emits no bins and
  # omits the *_at_ms offsets, but still reports the width. The bins/timestamp
  # checks remain as defensive fallbacks. A genuinely old build carries none of
  # these and yields nil, keeping the sidecar backward compatible.
  defp interval_evidence?(record, bins) do
    Map.has_key?(record, "interval_bin_width_ms") or bins != [] or
      has_interval_timestamps?(record)
  end

  defp has_interval_timestamps?(record) do
    Enum.any?(@interval_timestamp_fields, fn field -> Map.has_key?(record, field) end)
  end

  defp normalize_interval_bins(bins) when is_list(bins) do
    Enum.map(bins, fn bin ->
      %{
        start_offset_ms: Map.get(bin, "start_offset_ms"),
        stream_bytes: Map.get(bin, "stream_bytes"),
        datagram_bytes: Map.get(bin, "datagram_bytes"),
        datagrams: Map.get(bin, "datagrams"),
        stream_payload_events: Map.get(bin, "stream_payload_events"),
        streams_completed: Map.get(bin, "streams_completed")
      }
    end)
  end

  defp normalize_interval_bins(_other), do: []

  defp object_delivery(record) do
    case Map.get(record, "object_delivery") do
      %{} = object ->
        if object_delivery_present?(object) do
          %{
            count: Map.get(object, "count"),
            min_ms: Map.get(object, "min_ms"),
            p50_ms: Map.get(object, "p50_ms"),
            p90_ms: Map.get(object, "p90_ms"),
            p99_ms: Map.get(object, "p99_ms")
          }
        end

      _other ->
        nil
    end
  end

  defp object_delivery_present?(object) do
    count = Map.get(object, "count")
    is_number(count) and count > 0
  end

  defp evidence_complete?(receipt, record) do
    if expected_receiver_complete?(receipt) do
      Map.get(record, "receiver_evidence_complete", true)
    else
      true
    end
  end

  defp expected_receiver_complete?(%RunReceipt{expected: expected}) do
    Map.has_key?(expected, :receiver_evidence_complete) or
      Map.has_key?(expected, "receiver_evidence_complete")
  end

  defp observed_counters(record) do
    counters =
      Map.new(@counter_fields, fn field -> {String.to_atom(field), Map.get(record, field)} end)

    @interval_timestamp_fields
    |> Enum.filter(fn field -> Map.has_key?(record, field) end)
    |> Enum.reduce(counters, fn field, acc ->
      Map.put(acc, String.to_atom(field), Map.get(record, field))
    end)
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

  defp post_api_json(base_url, path, payload, timeout_ms) do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)

    url = base_url |> String.trim_trailing("/") |> Kernel.<>(path)
    body = JSON.encode!(payload)
    request = {String.to_charlist(url), [], ~c"application/json", body}
    http_options = [{:timeout, timeout_ms}]
    options = [body_format: :binary]

    case :httpc.request(:post, request, http_options, options) do
      {:ok, {{_version, status, _reason}, _headers, body}} when status in 200..299 ->
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

  defp decode_error_body(body) do
    JSON.decode!(body)
  rescue
    _reason -> body
  end
end
