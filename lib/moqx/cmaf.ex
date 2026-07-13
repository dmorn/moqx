defmodule MOQX.CMAF do
  @moduledoc "Helpers for capturing catalog-advertised CMAF tracks."

  alias MOQX.{Catalog, Client, Object}
  alias MOQX.Catalog.Track

  defmodule Capture do
    @moduledoc "Report for one completed CMAF capture."

    @enforce_keys [:path, :track, :object_count, :init_bytes, :media_bytes]
    defstruct [
      :path,
      :track,
      :object_count,
      :init_bytes,
      :media_bytes,
      :first_group_id,
      :last_group_id
    ]

    @type t :: %__MODULE__{
            path: Path.t(),
            track: Track.t(),
            object_count: pos_integer(),
            init_bytes: non_neg_integer(),
            media_bytes: non_neg_integer(),
            first_group_id: non_neg_integer(),
            last_group_id: non_neg_integer()
          }
  end

  @doc """
  Captures a catalog-selected H.264 CMAF track into a fragmented MP4 file.

  The initialization segment is written first. Media objects are ordered by
  group, subgroup and object coordinates before being appended. Both temporary
  subscriptions are ended before this function returns.
  """
  @spec capture(Client.t(), Catalog.t(), Path.t(), keyword()) ::
          {:ok, Capture.t()} | {:error, term()}
  def capture(%Client{} = client, %Catalog{} = catalog, path, options \\ []) do
    object_count = Keyword.get(options, :objects, 30)
    timeout = Keyword.get(options, :timeout, 10_000)

    with true <- is_integer(object_count) and object_count > 0,
         {:ok, track} <- Catalog.select_h264(catalog),
         :ok <- validate_track(track),
         {:ok, init_payload} <- capture_init(client, track, timeout),
         {:ok, objects} <- capture_media(client, track, object_count, timeout),
         {:ok, report} <- write_capture(path, track, init_payload, objects) do
      {:ok, report}
    else
      false -> {:error, :invalid_object_count}
      {:error, _reason} = error -> error
    end
  end

  defp validate_track(%Track{packaging: "cmaf", init_track: init_track})
       when is_binary(init_track),
       do: :ok

  defp validate_track(%Track{packaging: packaging}),
    do: {:error, {:unsupported_packaging, packaging}}

  defp capture_init(client, track, timeout) do
    init_ref = %{Track.track_ref(track) | track: track.init_track}

    with {:ok, subscription} <- MOQX.subscribe(client, init_ref) do
      try do
        case await_objects(client, subscription, 1, timeout) do
          {:ok, [%Object{payload: payload}]} -> {:ok, payload}
          {:error, _reason} = error -> error
        end
      after
        _result = MOQX.unsubscribe(client, subscription)
      end
    end
  end

  defp capture_media(client, track, object_count, timeout) do
    with {:ok, subscription} <- MOQX.subscribe(client, Track.track_ref(track)) do
      try do
        await_objects(client, subscription, object_count, timeout)
      after
        _result = MOQX.unsubscribe(client, subscription)
      end
    end
  end

  defp await_objects(client, subscription, count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_objects(client, subscription, count, deadline, [])
  end

  defp await_objects(_client, _subscription, 0, _deadline, objects),
    do: {:ok, Enum.reverse(objects)}

  defp await_objects(client, subscription, remaining, deadline, objects) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:moqx, ^client, {:object, %Object{subscription: ^subscription} = object}} ->
        await_objects(client, subscription, remaining - 1, deadline, [object | objects])

      {:moqx, ^client, {:subscription_error, ^subscription, reason}} ->
        {:error, {:subscription_error, reason}}

      {:moqx, ^client, {:object_status, %Object{subscription: ^subscription} = object}} ->
        {:error, {:object_status, object.status}}

      {:moqx, ^client, {:error, reason}} ->
        {:error, reason}
    after
      timeout -> {:error, {:object_timeout, subscription.track}}
    end
  end

  defp write_capture(path, track, init_payload, objects) do
    objects = Enum.sort_by(objects, &object_coordinates/1)
    media_payload = Enum.map(objects, & &1.payload)
    temporary_path = path <> ".part"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary_path, [init_payload, media_payload]),
         :ok <- File.rename(temporary_path, path) do
      groups = Enum.map(objects, & &1.group_id)

      {:ok,
       %Capture{
         path: path,
         track: track,
         object_count: length(objects),
         init_bytes: byte_size(init_payload),
         media_bytes: Enum.reduce(objects, 0, &(byte_size(&1.payload) + &2)),
         first_group_id: Enum.min(groups),
         last_group_id: Enum.max(groups)
       }}
    else
      {:error, reason} ->
        _result = File.rm(temporary_path)
        {:error, {:file_error, reason}}
    end
  end

  defp object_coordinates(%Object{} = object) do
    {object.group_id, object.subgroup_id || 0, object.object_id}
  end
end
