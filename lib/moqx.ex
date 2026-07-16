defmodule MOQX do
  @moduledoc """
  Elixir Media over QUIC library.

  Protocol code is built on top of a small transport adapter boundary so that
  native QUIC and deterministic support transports can share the same contract.
  """

  alias MOQX.Protocol.Resolver
  alias MOQX.Runtime.ConnectionDriver

  @doc "Returns the default native QUIC transport implementation."
  @spec transport() :: module()
  def transport do
    MOQX.Transport.Quicer
  end

  @doc "Connects to an endpoint using one explicitly selected protocol implementation."
  @spec connect(binary() | URI.t(), keyword()) :: {:ok, MOQX.Client.t()} | {:error, term()}
  def connect(endpoint, options) when is_binary(endpoint) or is_struct(endpoint, URI) do
    with {:ok, event_recipient} <- event_recipient(options),
         {:ok, endpoint} <- parse_endpoint(endpoint),
         {:ok, protocol} <- Resolver.fetch(Keyword.fetch!(options, :protocol)) do
      ConnectionDriver.start(endpoint, protocol, options, event_recipient)
    end
  rescue
    KeyError -> {:error, :protocol_required}
  end

  defp event_recipient(options) do
    case Keyword.get(options, :events_to, self()) do
      pid when is_pid(pid) -> {:ok, pid}
      _other -> {:error, :events_to_must_be_a_pid}
    end
  end

  @doc "Subscribes to a protocol-neutral track address."
  @spec subscribe(MOQX.Client.t(), MOQX.TrackRef.t(), keyword()) ::
          {:ok, MOQX.Subscription.t()} | {:error, term()}
  def subscribe(client, track, options \\ []) do
    ConnectionDriver.subscribe(client, track, options)
  end

  @doc "Ends an active subscription and sends the selected protocol's unsubscribe message."
  @spec unsubscribe(MOQX.Client.t(), MOQX.Subscription.t()) :: :ok | {:error, term()}
  def unsubscribe(client, subscription) do
    ConnectionDriver.unsubscribe(client, subscription)
  end

  @doc "Advertises a namespace through the selected protocol implementation."
  @spec publish(MOQX.Client.t(), [binary()], keyword()) ::
          {:ok, MOQX.Publication.t()} | {:error, term()}
  def publish(client, namespace, options \\ []) when is_list(namespace) do
    ConnectionDriver.publish(client, namespace, options)
  end

  @doc "Registers a track under an active publication."
  @spec add_track(MOQX.Client.t(), MOQX.Publication.t(), binary(), keyword()) ::
          {:ok, MOQX.PublishedTrack.t()} | {:error, term()}
  def add_track(client, publication, track, options \\ []) when is_binary(track) do
    ConnectionDriver.add_track(client, publication, track, options)
  end

  @doc "Accepts one pending inbound publisher subscription."
  @spec accept_subscription(
          MOQX.Client.t(),
          MOQX.PublicationSubscriptionRequest.t(),
          MOQX.PublishedTrack.t(),
          keyword()
        ) :: :ok | {:error, term()}
  def accept_subscription(client, request, published_track, options \\ []) do
    ConnectionDriver.accept_subscription(client, request, published_track, options)
  end

  @doc "Rejects one pending inbound publisher subscription."
  @spec reject_subscription(
          MOQX.Client.t(),
          MOQX.PublicationSubscriptionRequest.t(),
          MOQX.SubscriptionRejection.t()
        ) :: :ok | {:error, term()}
  def reject_subscription(client, request, rejection) do
    ConnectionDriver.reject_subscription(client, request, rejection)
  end

  @doc "Publishes one object on a registered track."
  @spec publish_object(MOQX.Client.t(), MOQX.PublishedTrack.t(), MOQX.Object.t()) ::
          :ok | {:error, term()}
  def publish_object(client, track, object) do
    ConnectionDriver.publish_object(client, track, object)
  end

  @doc "Finishes every active delivery and withdraws a namespace publication."
  @spec finish_publication(MOQX.Client.t(), MOQX.Publication.t(), keyword()) ::
          :ok | {:error, term()}
  def finish_publication(client, publication, options \\ []) do
    ConnectionDriver.finish_publication(client, publication, options)
  end

  @doc "Gracefully closes the selected protocol connection."
  @spec close(MOQX.Client.t(), keyword()) :: :ok | {:error, term()}
  def close(client, options \\ []) do
    ConnectionDriver.close(client, Keyword.get(options, :reason))
  end

  defp parse_endpoint(%URI{host: host} = endpoint) when is_binary(host), do: {:ok, endpoint}

  defp parse_endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{host: host} = uri when is_binary(host) -> {:ok, uri}
      _uri -> {:error, :invalid_endpoint}
    end
  end
end
