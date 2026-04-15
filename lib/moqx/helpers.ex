defmodule MOQX.Helpers do
  @moduledoc """
  Optional convenience helpers built on top of the low-level `MOQX` core API.

  This module composes core primitives and typed lifecycle events; it does not
  change core message contracts.
  """

  @typedoc "Raw CMSF catalog payload bytes (UTF-8 JSON)."
  @type catalog_payload :: MOQX.catalog_payload()

  @doc """
  Creates and publishes the initial catalog object on the `"catalog"` track.
  """
  @spec publish_catalog(MOQX.broadcast(), catalog_payload()) ::
          {:ok, MOQX.track()} | {:error, MOQX.RequestError.t()}
  def publish_catalog(broadcast, catalog_payload) when is_binary(catalog_payload) do
    with {:ok, catalog_track} <- MOQX.create_track(broadcast, "catalog"),
         :ok <- update_catalog(catalog_track, catalog_payload) do
      {:ok, catalog_track}
    end
  end

  @doc """
  Writes one catalog object to an existing catalog track.
  """
  @spec update_catalog(MOQX.track(), catalog_payload()) :: :ok | {:error, MOQX.RequestError.t()}
  def update_catalog(track, catalog_payload) when is_binary(catalog_payload) do
    MOQX.write_frame(track, catalog_payload)
  end

  @doc """
  Fetches the raw catalog track bytes.

  Thin wrapper over `MOQX.fetch/4` with catalog defaults.

  ## Options

    * `:namespace` - broadcast namespace. Default: `"moqtail"`.
    * `:track` - catalog track name. Default: `"catalog"`.
    * any other options are passed through to `MOQX.fetch/4`.
  """
  @spec fetch_catalog(MOQX.session(), Keyword.t()) ::
          {:ok, MOQX.fetch_ref()} | {:error, MOQX.RequestError.t()}
  def fetch_catalog(session, opts \\ []) when is_list(opts) do
    namespace = opts |> Keyword.get(:namespace, "moqtail") |> normalize_namespace!()
    track = opts |> Keyword.get(:track, "catalog") |> normalize_track!()

    fetch_opts =
      opts
      |> Keyword.delete(:namespace)
      |> Keyword.delete(:track)
      |> Keyword.put_new(:priority, 0)
      |> Keyword.put_new(:group_order, :original)
      |> Keyword.put_new(:start, {0, 0})
      |> Keyword.put_new(:end, {0, 1})

    MOQX.fetch(session, namespace, track, fetch_opts)
  end

  @doc """
  Collects fetch messages for `ref` and decodes the payload as a CMSF catalog.
  """
  @spec await_catalog(MOQX.fetch_ref(), timeout()) ::
          {:ok, MOQX.Catalog.t()} | {:error, String.t()}
  def await_catalog(ref, timeout \\ 5_000) when is_reference(ref) do
    await_catalog_loop(ref, [], timeout)
  end

  @doc """
  Waits until the given publisher track becomes active.

  Returns `:ok` on activation, `{:error, :timeout}` if no lifecycle event
  arrives within `timeout`, or `{:error, %MOQX.RequestError{code: :track_closed}}`
  if the track closes first.
  """
  @spec await_track_active(MOQX.track(), timeout()) ::
          :ok | {:error, :timeout | MOQX.RequestError.t()}
  def await_track_active(track, timeout \\ 5_000) when is_reference(track) do
    receive do
      {:moqx_track_active, %MOQX.TrackActive{track: ^track}} ->
        :ok

      {:moqx_track_closed, %MOQX.TrackClosed{track: ^track}} ->
        {:error,
         %MOQX.RequestError{
           op: :write_frame,
           code: :track_closed,
           message: "track_closed",
           handle: track
         }}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Waits for track activation, then writes one frame.
  """
  @spec write_frame_when_active(MOQX.track(), binary(), timeout()) ::
          :ok | {:error, :timeout | MOQX.RequestError.t()}
  def write_frame_when_active(track, payload, timeout \\ 5_000)
      when is_reference(track) and is_binary(payload) do
    with :ok <- await_track_active(track, timeout) do
      MOQX.write_frame(track, payload)
    end
  end

  defp await_catalog_loop(ref, acc, timeout) do
    receive do
      {:moqx_fetch_ok, %MOQX.FetchOk{ref: ^ref}} ->
        await_catalog_loop(ref, acc, timeout)

      {:moqx_fetch_object, %MOQX.FetchObject{ref: ^ref, payload: payload}} ->
        await_catalog_loop(ref, [acc | [payload]], timeout)

      {:moqx_fetch_done, %MOQX.FetchDone{ref: ^ref}} ->
        MOQX.Catalog.decode(IO.iodata_to_binary(acc))

      {:moqx_request_error, %MOQX.RequestError{op: :fetch, ref: ^ref, message: reason}} ->
        {:error, reason}

      {:moqx_transport_error, %MOQX.TransportError{op: :fetch, ref: ^ref, message: reason}} ->
        {:error, reason}
    after
      timeout -> {:error, "timeout"}
    end
  end

  defp normalize_namespace!(namespace) when is_binary(namespace), do: namespace

  defp normalize_namespace!(namespace) do
    raise ArgumentError,
          "expected catalog :namespace to be a string, got: #{inspect(namespace)}"
  end

  defp normalize_track!(track) when is_binary(track), do: track

  defp normalize_track!(track) do
    raise ArgumentError, "expected catalog :track to be a string, got: #{inspect(track)}"
  end
end
