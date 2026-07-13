defmodule MOQX.CMAF do
  @moduledoc "Helpers for capturing and publishing catalog-advertised CMAF tracks."

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

  defmodule Publication do
    @moduledoc "Handles and counts for one prepared CMAF file publication."

    @enforce_keys [
      :publication,
      :catalog_track,
      :init_track,
      :media_track,
      :fragment_count,
      :init_bytes,
      :media_bytes
    ]

    defstruct [
      :publication,
      :catalog_track,
      :init_track,
      :media_track,
      :fragment_count,
      :init_bytes,
      :media_bytes
    ]

    @type t :: %__MODULE__{
            publication: MOQX.Publication.t(),
            catalog_track: MOQX.PublishedTrack.t(),
            init_track: MOQX.PublishedTrack.t(),
            media_track: MOQX.PublishedTrack.t(),
            fragment_count: pos_integer(),
            init_bytes: pos_integer(),
            media_bytes: pos_integer()
          }
  end

  @doc """
  Publishes a fragmented MP4 as catalog, initialization, and media tracks.

  The file is prepared as retained content so a subscriber may arrive after
  namespace registration. The caller remains responsible for finishing the
  returned namespace publication.
  """
  @spec publish_file(Client.t(), Path.t(), keyword()) ::
          {:ok, Publication.t()} | {:error, term()}
  def publish_file(%Client{} = client, path, options) do
    namespace = Keyword.fetch!(options, :namespace)
    catalog_name = Keyword.get(options, :catalog_track, ".catalog")
    init_name = Keyword.get(options, :init_track, "init.mp4")
    media_name = Keyword.get(options, :media_track, "video.m4s")
    codec = Keyword.get(options, :codec, "avc1.42C01F")

    with {:ok, init, fragments} <- read_fragments(path),
         {:ok, publication} <- MOQX.publish(client, namespace),
         {:ok, catalog_track} <-
           MOQX.add_track(client, publication, catalog_name, retention: :latest),
         {:ok, init_track} <-
           MOQX.add_track(client, publication, init_name, retention: :latest),
         {:ok, media_track} <-
           MOQX.add_track(client, publication, media_name, retention: :all),
         :ok <-
           publish_payload(
             client,
             catalog_track,
             catalog_payload(namespace, init_name, media_name, codec),
             0
           ),
         :ok <- publish_payload(client, init_track, init, 0),
         :ok <- publish_fragments(client, media_track, fragments) do
      {:ok,
       %Publication{
         publication: publication,
         catalog_track: catalog_track,
         init_track: init_track,
         media_track: media_track,
         fragment_count: length(fragments),
         init_bytes: byte_size(init),
         media_bytes: Enum.reduce(fragments, 0, &(byte_size(&1) + &2))
       }}
    end
  rescue
    KeyError -> {:error, :namespace_required}
  end

  @doc "Splits a fragmented MP4 into its initialization bytes and `moof` fragments."
  @spec read_fragments(Path.t()) :: {:ok, binary(), [binary()]} | {:error, term()}
  def read_fragments(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, boxes} <- decode_boxes(bytes),
         {:ok, init, fragments} <- partition_fragments(boxes) do
      {:ok, init, fragments}
    else
      {:error, reason} when reason in [:enoent, :eacces, :eisdir] ->
        {:error, {:file_error, reason}}

      {:error, _reason} = error ->
        error
    end
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

  defp publish_payload(client, track, payload, group_id) do
    MOQX.publish_object(client, track, %Object{
      group_id: group_id,
      subgroup_id: 0,
      object_id: 0,
      publisher_priority: 127,
      payload: payload
    })
  end

  defp publish_fragments(client, track, fragments) do
    fragments
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {fragment, group_id}, :ok ->
      case publish_payload(client, track, fragment, group_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp catalog_payload(namespace, init_name, media_name, codec) do
    JSON.encode!(%{
      "version" => 1,
      "streamingFormat" => 1,
      "streamingFormatVersion" => "0.2",
      "supportsDeltaUpdates" => false,
      "commonTrackFields" => %{
        "namespace" => Enum.join(namespace, "/"),
        "packaging" => "cmaf"
      },
      "tracks" => [
        %{
          "name" => media_name,
          "initTrack" => init_name,
          "selectionParams" => %{"codec" => codec}
        }
      ]
    })
  end

  defp decode_boxes(bytes), do: decode_boxes(bytes, [])
  defp decode_boxes(<<>>, boxes), do: {:ok, Enum.reverse(boxes)}

  defp decode_boxes(<<1::32, type::binary-size(4), size::64, _rest::binary>> = bytes, boxes)
       when size >= 16 and byte_size(bytes) >= size do
    <<box::binary-size(^size), rest::binary>> = bytes
    decode_boxes(rest, [{type, box} | boxes])
  end

  defp decode_boxes(<<0::32, type::binary-size(4), _rest::binary>> = bytes, boxes) do
    {:ok, Enum.reverse([{type, bytes} | boxes])}
  end

  defp decode_boxes(<<size::32, type::binary-size(4), _rest::binary>> = bytes, boxes)
       when size >= 8 and byte_size(bytes) >= size do
    <<box::binary-size(^size), rest::binary>> = bytes
    decode_boxes(rest, [{type, box} | boxes])
  end

  defp decode_boxes(_bytes, _boxes), do: {:error, :invalid_iso_bmff}

  defp partition_fragments(boxes) do
    {init_boxes, media_boxes} = Enum.split_while(boxes, fn {type, _box} -> type != "moof" end)

    with false <- init_boxes == [],
         false <- media_boxes == [] do
      fragments =
        media_boxes
        |> Enum.chunk_while([], &fragment_chunk/2, &fragment_after/1)
        |> Enum.map(fn fragment ->
          fragment |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
        end)

      {:ok, init_boxes |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary(), fragments}
    else
      true -> {:error, :not_fragmented_mp4}
    end
  end

  defp fragment_chunk({"moof", _box} = box, []), do: {:cont, [box]}
  defp fragment_chunk({"moof", _box} = box, chunk), do: {:cont, Enum.reverse(chunk), [box]}
  defp fragment_chunk(box, chunk), do: {:cont, [box | chunk]}

  defp fragment_after([]), do: {:cont, []}
  defp fragment_after(chunk), do: {:cont, Enum.reverse(chunk), []}
end
