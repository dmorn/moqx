defmodule MOQX.Runtime.Profiles do
  @moduledoc false
  alias MOQX.Operation

  @profile_options [:profile, :max_catalog_bytes, :max_catalog_encoded_bytes]
  defstruct subscriptions: %{}, publications: %{}

  def prepare(%Operation.Subscribe{} = operation, protocol, _state) do
    profile = Keyword.get(operation.options, :profile, :none)

    with :ok <- MOQX.Profile.validate(profile, protocol),
         :ok <- validate_options(operation.options) do
      {:ok, %{operation | options: Keyword.drop(operation.options, @profile_options)}}
    end
  end

  def prepare(%Operation.AddTrack{} = operation, protocol, _state) do
    profile = Keyword.get(operation.options, :profile, :none)

    with :ok <- MOQX.Profile.validate(profile, protocol),
         :ok <- validate_options(operation.options) do
      {:ok,
       %{operation | options: Keyword.drop(operation.options, [:compression | @profile_options])}}
    end
  end

  def prepare(
        %Operation.PublishCatalog{track: track, catalog: %MOQX.Catalog{} = catalog},
        _protocol,
        state
      ) do
    with %{profile: profile, next_group: group, compression: compression} <-
           state.publications[track],
         true <- catalog.format == MOQX.Profile.format(profile),
         {:ok, payload} <- MOQX.Catalog.encode(catalog, compression: compression) do
      {:ok,
       %Operation.PublishObject{
         track: track,
         object: %MOQX.Object{
           group_id: group,
           object_id: 0,
           timestamp: 0,
           end_of_group?: true,
           payload: payload
         }
       }}
    else
      nil -> {:error, :unknown_catalog_publication}
      false -> {:error, :catalog_profile_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def prepare(%Operation.PublishCatalog{}, _protocol, _state), do: {:error, :invalid_catalog}

  def prepare(%Operation.PublishObject{track: track} = operation, _protocol, state) do
    if Map.has_key?(state.publications, track),
      do: {:error, :use_publish_catalog},
      else: {:ok, operation}
  end

  def prepare(%module{subscription: subscription} = operation, _protocol, state)
      when module in [Operation.Unsubscribe, Operation.UpdateSubscription] do
    if Map.has_key?(state.subscriptions, subscription),
      do: {:ok, operation},
      else: {:error, :unknown_subscription}
  end

  def prepare(operation, _protocol, _state), do: {:ok, operation}

  def commit(state, %Operation.Subscribe{options: options}, {:ok, subscription}) do
    profile = Keyword.get(options, :profile, :none)

    entry = %{
      profile: profile,
      last_group: -1,
      catalog: nil,
      options: [
        max_bytes: Keyword.get(options, :max_catalog_bytes, 1_048_576),
        max_encoded_bytes: Keyword.get(options, :max_catalog_encoded_bytes, 1_048_576),
        compression:
          if(profile == :hang and subscription.track.track == "catalog.json.z",
            do: :deflate,
            else: :none
          )
      ]
    }

    %{state | subscriptions: Map.put(state.subscriptions, subscription, entry)}
  end

  def commit(state, %Operation.Unsubscribe{subscription: subscription}, :ok) do
    %{state | subscriptions: Map.delete(state.subscriptions, subscription)}
  end

  def commit(state, %Operation.AddTrack{options: options}, {:ok, track}) do
    case Keyword.get(options, :profile, :none) do
      :none ->
        state

      profile ->
        entry = %{
          profile: profile,
          next_group: 0,
          compression: Keyword.get(options, :compression, :none)
        }

        %{state | publications: Map.put(state.publications, track, entry)}
    end
  end

  def commit(state, %Operation.PublishCatalog{track: track}, :ok) do
    update_in(state.publications[track].next_group, &(&1 + 1))
  end

  def commit(state, %Operation.WithdrawTrack{track: track}, :ok),
    do: %{state | publications: Map.delete(state.publications, track)}

  def commit(state, %Operation.FinishPublication{publication: publication}, :ok),
    do: drop_publication(state, publication)

  def commit(state, _operation, _reply), do: state

  def event(state, %MOQX.Event.ObjectReceived{object: object} = event) do
    case Map.get(state.subscriptions, object.subscription) do
      nil -> {state, [event]}
      %{profile: :none} -> {state, [event]}
      entry -> catalog_event(state, entry, object)
    end
  end

  def event(state, %module{subscription: subscription} = event)
      when module in [MOQX.Event.SubscriptionDone, MOQX.Event.SubscriptionFailed] do
    {%{state | subscriptions: Map.delete(state.subscriptions, subscription)}, [event]}
  end

  def event(state, %module{publication: publication} = event)
      when module in [MOQX.Event.PublicationFailed, MOQX.Event.PublicationCancelled],
      do: {drop_publication(state, publication), [event]}

  def event(state, %MOQX.Event.PublicationTrackFailed{track: track} = event),
    do: {%{state | publications: Map.delete(state.publications, track)}, [event]}

  def event(_state, %MOQX.Event.ConnectionClosed{} = event), do: {%__MODULE__{}, [event]}
  def event(state, event), do: {state, [event]}

  defp validate_options(options) do
    limits = [
      Keyword.get(options, :max_catalog_bytes, 1_048_576),
      Keyword.get(options, :max_catalog_encoded_bytes, 1_048_576)
    ]

    if Enum.all?(limits, &(is_integer(&1) and &1 > 0)),
      do: :ok,
      else: {:error, :invalid_catalog_options}
  end

  defp drop_publication(state, publication) do
    %{
      state
      | publications:
          Map.reject(state.publications, fn {track, _entry} ->
            track.publication == publication
          end)
    }
  end

  defp catalog_event(state, %{profile: :hang, last_group: last}, %{group_id: group})
       when group < last,
       do: {state, []}

  defp catalog_event(state, %{profile: :hang, last_group: last} = entry, object)
       when object.group_id == last or object.object_id != 0 do
    catalog_error(state, entry, object, %MOQX.Catalog.Error{
      path: [],
      reason: :invalid_catalog_group
    })
  end

  defp catalog_event(state, entry, object) do
    case MOQX.Profile.decode(
           entry.profile,
           object.payload,
           object.subscription.track.namespace,
           entry.options
         ) do
      {:ok, catalog} ->
        {added, removed, changed} = changes(entry.catalog, catalog)

        event = %MOQX.Event.CatalogReceived{
          subscription: object.subscription,
          catalog: catalog,
          group_id: object.group_id,
          added: added,
          removed: removed,
          changed: changed
        }

        entry = %{entry | last_group: object.group_id, catalog: catalog}

        {%{state | subscriptions: Map.put(state.subscriptions, object.subscription, entry)},
         [event]}

      {:error, error} ->
        catalog_error(state, entry, object, error)
    end
  end

  defp catalog_error(state, entry, object, error) do
    entry = %{entry | last_group: max(entry.last_group, object.group_id)}

    {%{state | subscriptions: Map.put(state.subscriptions, object.subscription, entry)},
     [%MOQX.Event.CatalogFailed{subscription: object.subscription, error: error}]}
  end

  defp changes(previous, current) do
    before = tracks(previous)
    after_update = tracks(current)
    added = Map.keys(Map.drop(after_update, Map.keys(before))) |> Enum.sort()
    removed = Map.keys(Map.drop(before, Map.keys(after_update))) |> Enum.sort()

    changed =
      for {ref, track} <- after_update, Map.has_key?(before, ref), before[ref] != track, do: ref

    {added, removed, Enum.sort(changed)}
  end

  defp tracks(nil), do: %{}

  defp tracks(catalog) do
    for track <- catalog.tracks,
        ref = MOQX.Catalog.track_ref(catalog, track),
        is_struct(ref, MOQX.TrackRef),
        into: %{},
        do: {ref, track}
  end
end
