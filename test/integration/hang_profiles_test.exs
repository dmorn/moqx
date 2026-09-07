defmodule MOQX.Integration.HangProfilesTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag :hang_profiles

  test "pinned Lite05 relay delivers retained HANG catalogs to concurrent and late subscribers" do
    namespace = ["hang44", Integer.to_string(System.unique_integer([:positive]))]
    {:ok, publisher} = connect(:publisher)
    {:ok, subscriber} = connect(:subscriber)

    on_exit(fn ->
      MOQX.close(publisher)
      MOQX.close(subscriber)
    end)

    assert {:ok, publication} = MOQX.publish(publisher, namespace)
    assert_receive {:moqx, ^publisher, %MOQX.Event.PublicationReady{}}, 5_000
    assert {:ok, plain} = MOQX.add_catalog(publisher, publication, profile: :hang)

    assert {:ok, compressed} =
             MOQX.add_catalog(publisher, publication, profile: :hang, compression: :deflate)

    {:ok, catalog} =
      MOQX.Catalog.decode(~s({"video":{"renditions":{"v":{"codec":"avc1.42C01F"}}}}),
        format: :hang
      )

    assert :ok = MOQX.publish_catalog(publisher, plain, catalog)
    assert :ok = MOQX.publish_catalog(publisher, compressed, catalog)
    assert {:ok, first} = MOQX.subscribe(subscriber, plain.track, profile: :hang)
    assert {:ok, second} = MOQX.subscribe(subscriber, compressed.track, profile: :hang)

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.CatalogReceived{subscription: ^first, catalog: first_catalog}},
                   5_000

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.CatalogReceived{subscription: ^second, catalog: second_catalog}},
                   5_000

    assert first_catalog.raw == second_catalog.raw
    {:ok, empty} = MOQX.Catalog.decode("{}", format: :hang)
    assert :ok = MOQX.publish_catalog(publisher, plain, empty)

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.CatalogReceived{
                      subscription: ^first,
                      catalog: %{tracks: []},
                      group_id: 1
                    }},
                   5_000

    assert {:ok, late} = MOQX.subscribe(subscriber, plain.track, profile: :hang)

    assert_receive {:moqx, ^subscriber,
                    %MOQX.Event.CatalogReceived{
                      subscription: ^late,
                      catalog: %{tracks: []},
                      group_id: 1
                    }},
                   5_000

    assert :ok = MOQX.unsubscribe(subscriber, first)
    assert :ok = MOQX.withdraw_track(publisher, plain)
    assert :ok = MOQX.finish_publication(publisher, publication)
  end

  test "pinned relay discovery reports additions, withdrawal, resubscription and abrupt owner exit" do
    prefix = "discover44/#{System.unique_integer([:positive])}/"
    {:ok, watcher} = connect(:subscriber)
    {:ok, publisher} = connect(:publisher)

    on_exit(fn ->
      MOQX.close(watcher)
      MOQX.close(publisher)
    end)

    assert {:ok, discovery} = MOQX.discover(watcher, prefix)
    assert_receive {:moqx, ^watcher, %MOQX.Event.DiscoveryReady{discovery: ^discovery}}, 5_000
    path = prefix <> "alice.hang"
    assert {:ok, publication} = MOQX.publish(publisher, String.split(path, "/"))

    assert_receive {:moqx, ^watcher,
                    %MOQX.Event.BroadcastAvailable{discovery: ^discovery, path: ^path}},
                   5_000

    assert :ok = MOQX.cancel_discovery(watcher, discovery)

    assert_receive {:moqx, ^watcher,
                    %MOQX.Event.BroadcastWithdrawn{
                      discovery: ^discovery,
                      path: ^path,
                      reason: :cancelled
                    }},
                   5_000

    assert {:ok, again} = MOQX.discover(watcher, prefix)

    assert_receive {:moqx, ^watcher,
                    %MOQX.Event.BroadcastAvailable{discovery: ^again, path: ^path}},
                   5_000

    assert_receive {:moqx, ^watcher, %MOQX.Event.DiscoveryReady{discovery: ^again}}, 5_000
    assert :ok = MOQX.finish_publication(publisher, publication)

    assert_receive {:moqx, ^watcher,
                    %MOQX.Event.BroadcastWithdrawn{discovery: ^again, path: ^path}},
                   5_000

    owner =
      Task.async(fn ->
        {:ok, client} = connect(:publisher)
        {:ok, _publication} = MOQX.publish(client, String.split(path, "/"))

        receive do
          :exit -> :ok
        end
      end)

    assert_receive {:moqx, ^watcher,
                    %MOQX.Event.BroadcastAvailable{discovery: ^again, path: ^path}},
                   5_000

    send(owner.pid, :exit)
    Task.await(owner)
    # Pinned relay defaults to a five-second reconnect linger after abrupt loss.
    assert_receive {:moqx, ^watcher,
                    %MOQX.Event.BroadcastWithdrawn{discovery: ^again, path: ^path}},
                   10_000
  end

  test "native QUIC drains a final catalog after a conforming inclusive SUBSCRIBE_END" do
    {client, peer} = MOQX.ProfilePeer.start(native: true)

    {:ok, sub} =
      MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["room"], track: "catalog.json"},
        profile: :hang
      )

    send(peer.pid, {:accept, sub.id})
    assert_receive {:moqx, ^client, %MOQX.Event.SubscriptionAccepted{subscription: ^sub}}, 5_000
    send(peer.pid, {:finish_subscription, sub.id, 0})
    refute_receive {:moqx, ^client, %MOQX.Event.ProtocolFailed{}}, 50
    send(peer.pid, {:object, sub.id, 0, "{}"})
    assert_receive {:moqx, ^client, %MOQX.Event.CatalogReceived{subscription: ^sub}}, 5_000
    assert_receive {:moqx, ^client, %MOQX.Event.SubscriptionDone{subscription: ^sub}}, 5_000
    MOQX.close(client)
    send(peer.pid, :done)
    Task.await(peer)
  end

  defp connect(role) do
    MOQX.connect("moql://localhost:4463/",
      protocol: :moq_lite_05,
      role: role,
      connect_options: [cacertfile: Path.expand(".tmp/integration-certs/ca.pem")]
    )
  end
end
