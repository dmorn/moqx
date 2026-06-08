defmodule MOQX.MOQLite04.PublisherOperationsTest do
  use ExUnit.Case, async: true

  alias MOQX.MOQLite04
  alias MOQX.MOQLite04.Client
  alias MOQX.MOQLite04.Session
  alias MOQX.Transport
  alias MOQX.Transport.Support

  test "publisher accepts a subscription and publishes a group frame" do
    %{subscriber: subscriber, publisher: publisher} = connected_clients()
    subscribe = subscribe_message()
    subscribe_ok = subscribe_ok_message()
    group = %MOQLite04.Group{subscribe_id: subscribe.subscribe_id, group_sequence: 7}
    frame = %MOQLite04.Frame{payload: "original payload"}

    assert {:ok, %Client{} = subscriber, subscribe_stream, []} =
             MOQLite04.subscribe(subscriber, subscribe)

    publisher = sync_context(publisher, subscriber)

    assert {:ok, %Client{} = publisher, publisher_subscribe_stream} =
             MOQLite04.accept_stream(publisher, 100)

    subscriber = sync_context(subscriber, publisher)

    assert {:ok, %Client{} = publisher,
            [
              {:stream_started, 0, ^publisher_subscribe_stream, :subscribe},
              {:message, 0, ^publisher_subscribe_stream, ^subscribe}
            ]} = recv_until_protocol_event(publisher)

    subscriber = sync_context(subscriber, publisher)

    assert {:ok, %Client{} = publisher, ^publisher_subscribe_stream, []} =
             MOQLite04.subscribe_ok(publisher, publisher_subscribe_stream, subscribe_ok)

    subscriber = sync_context(subscriber, publisher)

    assert {:ok, %Client{} = subscriber, [{:message, 0, ^subscribe_stream, ^subscribe_ok}]} =
             recv_until_protocol_event(subscriber)

    publisher = sync_context(publisher, subscriber)

    assert {:ok, %Client{} = publisher, group_stream, []} =
             MOQLite04.publish_group(publisher, group, [frame])

    assert group_stream.info.direction == :unidirectional
    assert group_stream.info.initiator == :local

    subscriber = sync_context(subscriber, publisher)

    assert {:ok, %Client{} = subscriber, subscriber_group_stream} =
             MOQLite04.accept_stream(subscriber, 100)

    publisher = sync_context(publisher, subscriber)

    assert {:ok, %Client{},
            [
              {:stream_started, 1, ^subscriber_group_stream, :group},
              {:message, 1, ^subscriber_group_stream, ^group},
              {:message, 1, ^subscriber_group_stream, ^frame}
            ]} = recv_until_protocol_event(subscriber)

    publisher = sync_context(publisher, subscriber)

    assert publisher.context == subscriber.context
  end

  test "subscribe_drop before subscribe_ok is rejected through the client API" do
    %{publisher: publisher, publisher_subscribe_stream: publisher_subscribe_stream} =
      publisher_with_pending_subscription()

    drop = %MOQLite04.SubscribeDrop{start_group: 0, end_group: 0, error_code: 99}

    assert {:error, %Client{}, %MOQLite04.Error{} = error, []} =
             MOQLite04.subscribe_drop(publisher, publisher_subscribe_stream, drop)

    assert error.reason == :protocol_violation
    assert error.details == %{stream_type: :subscribe, message: :subscribe_drop}
  end

  test "duplicate announce status for one suffix is rejected through the client API" do
    %{publisher: publisher, publisher_announce_stream: publisher_announce_stream} =
      publisher_with_announce_interest()

    active = %MOQLite04.Announce{
      status: :active,
      broadcast_path_suffix: "live",
      hop_ids: [1]
    }

    assert {:ok, %Client{} = publisher, ^publisher_announce_stream, []} =
             MOQLite04.announce(publisher, publisher_announce_stream, active)

    assert {:error, %Client{}, %MOQLite04.Error{} = error, []} =
             MOQLite04.announce(publisher, publisher_announce_stream, active)

    assert error.reason == :protocol_violation

    assert error.details == %{
             stream_type: :announce,
             broadcast_path_suffix: "live",
             status: :active
           }
  end

  test "group publishing is rejected unless the peer subscription is active" do
    %{publisher: publisher} = connected_clients()
    group = %MOQLite04.Group{subscribe_id: 42, group_sequence: 7}
    frame = %MOQLite04.Frame{payload: "frame"}

    assert {:error, %Client{}, %MOQLite04.Error{} = error, []} =
             MOQLite04.publish_group(publisher, group, [frame])

    assert error.reason == :not_found
    assert error.details == %{stream_type: :group, subscribe_id: 42}
  end

  defp connected_clients do
    {:ok, network} = Support.start_network()
    {:ok, context} = Transport.new(Support, network: network, profile: :moq_lite_04)
    assert {:ok, listener, context} = Transport.listen(context, 0)
    assert {:ok, {_ip, port}} = Transport.local_address(context, listener)
    uri = URI.parse("moq-lite://localhost:#{port}/live")

    assert {:ok, subscriber_connection, context} =
             Transport.connect(context, "localhost", port, [], 100)

    assert {:ok, publisher_connection, context} = Transport.accept(context, listener, [], 100)

    assert {:ok, subscriber_connection, context} =
             Transport.handshake(context, subscriber_connection, 100)

    assert {:ok, publisher_connection, context} =
             Transport.handshake(context, publisher_connection, 100)

    subscriber = %Client{
      uri: uri,
      context: context,
      connection: subscriber_connection,
      session: Session.new()
    }

    publisher = %Client{
      uri: uri,
      context: context,
      connection: publisher_connection,
      session: Session.new()
    }

    %{subscriber: subscriber, publisher: publisher}
  end

  defp sync_context(%Client{} = target, %Client{} = source),
    do: %{target | context: source.context}

  defp publisher_with_pending_subscription do
    %{subscriber: subscriber, publisher: publisher} = connected_clients()
    subscribe = subscribe_message()

    assert {:ok, %Client{} = subscriber, _subscribe_stream, []} =
             MOQLite04.subscribe(subscriber, subscribe)

    publisher = sync_context(publisher, subscriber)

    assert {:ok, %Client{} = publisher, publisher_subscribe_stream} =
             MOQLite04.accept_stream(publisher, 100)

    assert {:ok, %Client{} = publisher,
            [
              {:stream_started, 0, ^publisher_subscribe_stream, :subscribe},
              {:message, 0, ^publisher_subscribe_stream, ^subscribe}
            ]} = recv_until_protocol_event(publisher)

    %{publisher: publisher, publisher_subscribe_stream: publisher_subscribe_stream}
  end

  defp publisher_with_announce_interest do
    %{subscriber: subscriber, publisher: publisher} = connected_clients()
    interest = %MOQLite04.AnnounceInterest{broadcast_path_prefix: "broadcast/", exclude_hop: 7}

    assert {:ok, %Client{} = subscriber, _announce_stream, []} =
             MOQLite04.announce_interest(subscriber, interest)

    publisher = sync_context(publisher, subscriber)

    assert {:ok, %Client{} = publisher, publisher_announce_stream} =
             MOQLite04.accept_stream(publisher, 100)

    assert {:ok, %Client{} = publisher,
            [
              {:stream_started, 0, ^publisher_announce_stream, :announce},
              {:message, 0, ^publisher_announce_stream, ^interest}
            ]} = recv_until_protocol_event(publisher)

    %{publisher: publisher, publisher_announce_stream: publisher_announce_stream}
  end

  defp recv_until_protocol_event(client, attempts \\ 20)

  defp recv_until_protocol_event(client, 0), do: {:error, client, :not_received, []}

  defp recv_until_protocol_event(client, attempts) do
    case MOQLite04.recv(client, 100) do
      {:ok, client, []} -> recv_until_protocol_event(client, attempts - 1)
      {:ok, _client, _events} = result -> result
      {:timeout, client} -> {:error, client, :timeout, []}
      {:error, client, reason, events} -> {:error, client, reason, events}
    end
  end

  defp subscribe_message do
    %MOQLite04.Subscribe{
      subscribe_id: 42,
      broadcast_path: "broadcast/live",
      track_name: "video",
      subscriber_priority: 128,
      subscriber_ordered: :ascending,
      subscriber_max_latency: 500,
      start_group: 0,
      end_group: 10
    }
  end

  defp subscribe_ok_message do
    %MOQLite04.SubscribeOk{
      publisher_priority: 192,
      publisher_ordered: :ascending,
      publisher_max_latency: 250,
      start_group: 0,
      end_group: 10
    }
  end
end
