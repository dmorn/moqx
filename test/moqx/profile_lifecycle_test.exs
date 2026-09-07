defmodule MOQX.ProfileLifecycleTest do
  use ExUnit.Case, async: true

  test "HANG snapshots replace live metadata, reject stale groups, and recover after malformed updates" do
    {client, peer} = peer()
    track = %MOQX.TrackRef{namespace: ["room", "alice"], track: "catalog.json"}
    assert {:ok, sub} = MOQX.subscribe(client, track, profile: :hang)
    send(peer.pid, {:accept, sub.id})
    assert_receive {:moqx, ^client, %MOQX.Event.SubscriptionAccepted{subscription: ^sub}}, 1_000
    first = ~s({"video":{"renditions":{"v":{"codec":"avc1.42C01F"}}}})
    send(peer.pid, {:object, sub.id, 1, first})

    assert_receive {:moqx, ^client, %MOQX.Event.CatalogReceived{subscription: ^sub} = event},
                   1_000

    assert event.added == [%MOQX.TrackRef{namespace: ["room", "alice"], track: "v"}]
    changed = ~s({"video":{"renditions":{"v":{"codec":"future-codec"}}}})
    send(peer.pid, {:object, sub.id, 2, changed})
    assert_receive {:moqx, ^client, %MOQX.Event.CatalogReceived{} = update}, 1_000
    assert update.changed == event.added
    assert [%{metadata_status: :unknown_codec}] = update.catalog.tracks
    send(peer.pid, {:object, sub.id, 3, "invalid"})
    assert_receive {:moqx, ^client, %MOQX.Event.CatalogFailed{subscription: ^sub}}, 1_000
    send(peer.pid, {:object, sub.id, 4, "{}"})

    assert_receive {:moqx, ^client, %MOQX.Event.CatalogReceived{catalog: %{tracks: []}} = empty},
                   1_000

    assert empty.removed == event.added
    send(peer.pid, {:object, sub.id, 0, first})
    refute_receive {:moqx, ^client, %MOQX.Event.CatalogReceived{}}, 100
    assert :ok = MOQX.unsubscribe(client, sub)
    assert :ok = MOQX.close(client)
    send(peer.pid, :done)
    Task.await(peer)
  end

  test "Lite discovery reports initial broadcasts, live changes and scoped cancellation" do
    {client, peer} = peer()
    assert {:ok, discovery} = MOQX.discover(client, "room/")
    send(peer.pid, {:discovery, discovery})

    assert_receive {:moqx, ^client,
                    %MOQX.Event.BroadcastAvailable{discovery: ^discovery, path: "room/alice"}},
                   1_000

    assert_receive {:moqx, ^client, %MOQX.Event.DiscoveryReady{discovery: ^discovery}}, 1_000
    send(peer.pid, :withdraw_broadcast)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.BroadcastWithdrawn{discovery: ^discovery, path: "room/alice"}},
                   1_000

    assert :ok = MOQX.cancel_discovery(client, discovery)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.DiscoveryDone{discovery: ^discovery, reason: :cancelled}},
                   1_000

    assert :ok = MOQX.close(client)
    send(peer.pid, :done)
    Task.await(peer)
  end

  test "a replacement broadcast withdraws the previous instance before reporting availability" do
    {client, peer} = peer()
    {:ok, discovery} = MOQX.discover(client, "room/")
    send(peer.pid, {:discovery, discovery})
    assert_receive {:moqx, ^client, %MOQX.Event.BroadcastAvailable{}}, 1_000
    assert_receive {:moqx, ^client, %MOQX.Event.DiscoveryReady{}}, 1_000
    send(peer.pid, {:broadcast, :active, "alice"})

    assert_receive {:moqx, ^client,
                    %MOQX.Event.BroadcastWithdrawn{
                      discovery: ^discovery,
                      path: "room/alice",
                      reason: :replaced
                    }},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.BroadcastAvailable{discovery: ^discovery, path: "room/alice"}},
                   1_000

    assert :ok = MOQX.cancel_discovery(client, discovery)
    MOQX.close(client)
    send(peer.pid, :done)
    Task.await(peer)
  end

  test "an unknown withdrawal terminates only its discovery and clears its broadcasts" do
    {client, peer} = peer()
    {:ok, discovery} = MOQX.discover(client, "room/")
    send(peer.pid, {:discovery, discovery})
    assert_receive {:moqx, ^client, %MOQX.Event.BroadcastAvailable{}}, 1_000
    assert_receive {:moqx, ^client, %MOQX.Event.DiscoveryReady{}}, 1_000
    send(peer.pid, {:broadcast, :ended, "unknown"})

    assert_receive {:moqx, ^client,
                    %MOQX.Event.BroadcastWithdrawn{
                      discovery: ^discovery,
                      path: "room/alice",
                      reason: :invalid_announcement
                    }},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.DiscoveryDone{
                      discovery: ^discovery,
                      reason: :invalid_announcement
                    }},
                   1_000

    assert {:error, :unknown_discovery} = MOQX.cancel_discovery(client, discovery)
    assert {:ok, _other} = MOQX.discover(client, "other/")
    refute_receive {:moqx, ^client, %MOQX.Event.ProtocolFailed{}}, 50
    MOQX.close(client)
    send(peer.pid, :done)
    Task.await(peer)
  end

  test "a foreign client's subscription cannot cancel or update a matching local subscription" do
    {first_client, first_peer} = peer()
    {second_client, second_peer} = peer()
    track = %MOQX.TrackRef{namespace: ["room", "alice"], track: "catalog.json"}
    {:ok, first} = MOQX.subscribe(first_client, track, profile: :hang)
    {:ok, second} = MOQX.subscribe(second_client, track, profile: :hang)
    assert first != second
    assert {:error, :unknown_subscription} = MOQX.unsubscribe(second_client, first)

    assert {:error, :unknown_subscription} =
             MOQX.update_subscription(second_client, first, priority: 7)

    send(first_peer.pid, {:accept, first.id})
    send(second_peer.pid, {:accept, second.id})

    assert_receive {:moqx, ^second_client,
                    %MOQX.Event.SubscriptionAccepted{subscription: ^second}},
                   1_000

    send(second_peer.pid, {:object, second.id, 0, "{}"})

    assert_receive {:moqx, ^second_client, %MOQX.Event.CatalogReceived{subscription: ^second}},
                   1_000

    MOQX.close(first_client)
    MOQX.close(second_client)
    send(first_peer.pid, :done)
    send(second_peer.pid, :done)
    Task.await(first_peer)
    Task.await(second_peer)
  end

  test "publication handles and selected profiles cannot leak between clients" do
    {first_client, first_peer} = peer()
    {second_client, second_peer} = peer()
    {:ok, first} = MOQX.publish(first_client, ["same"])
    {:ok, second} = MOQX.publish(second_client, ["same"])
    assert first != second
    assert {:error, _} = MOQX.add_catalog(second_client, first, profile: :hang)
    assert {:ok, own} = MOQX.add_catalog(second_client, second, profile: :hang)
    {:ok, empty} = MOQX.Catalog.decode("{}", format: :hang)
    assert :ok = MOQX.publish_catalog(second_client, own, empty)
    assert {:error, :unknown_catalog_publication} = MOQX.publish_catalog(first_client, own, empty)
    MOQX.close(first_client)
    MOQX.close(second_client)
    send(first_peer.pid, :done)
    send(second_peer.pid, :done)
    Task.await(first_peer)
    Task.await(second_peer)
  end

  test "the public profile matrix validates each supported and unsupported composition" do
    for protocol <- [:cloudflare_draft_14, :draft_16, :moq_lite_05],
        profile <- [:none, :cloudflare_cmsf, :moqtail_cmsf] do
      assert :ok = MOQX.Profile.validate(profile, protocol)
    end

    assert :ok = MOQX.Profile.validate(:hang, :moq_lite_05)

    for protocol <- [:cloudflare_draft_14, :draft_16] do
      assert {:error, {:unsupported_profile, :hang, ^protocol}} =
               MOQX.Profile.validate(:hang, protocol)
    end
  end

  test "profile options reject unsupported composition and malformed publication before mutation" do
    {client, peer} = peer()
    track = %MOQX.TrackRef{namespace: ["room"], track: "catalog.json"}

    assert {:error, {:unsupported_profile, :unknown, :moq_lite_05}} =
             MOQX.subscribe(client, track, profile: :unknown)

    assert {:error, :invalid_catalog_options} =
             MOQX.subscribe(client, track, profile: :hang, max_catalog_bytes: 0)

    {:ok, publication} = MOQX.publish(client, ["room"])

    assert {:error, :unsupported_catalog_encoding} =
             MOQX.add_catalog(client, publication, profile: :moqtail_cmsf, compression: :deflate)

    {:ok, catalog_track} = MOQX.add_catalog(client, publication, profile: :hang)
    assert {:error, :invalid_catalog} = MOQX.publish_catalog(client, catalog_track, %{})
    {:ok, empty} = MOQX.Catalog.decode("{}", format: :hang)
    assert :ok = MOQX.publish_catalog(client, catalog_track, empty)
    assert :ok = MOQX.withdraw_track(client, catalog_track)

    assert {:error, :unknown_catalog_publication} =
             MOQX.publish_catalog(client, catalog_track, empty)

    MOQX.close(client)
    send(peer.pid, :done)
    Task.await(peer)
  end

  test "connection loss withdraws discovered broadcasts and terminates discovery" do
    {client, peer} = peer()
    {:ok, discovery} = MOQX.discover(client, "room/")
    send(peer.pid, {:discovery, discovery})
    assert_receive {:moqx, ^client, %MOQX.Event.DiscoveryReady{}}, 1_000
    send(peer.pid, :close_connection)

    assert_receive {:moqx, ^client,
                    %MOQX.Event.BroadcastWithdrawn{
                      discovery: ^discovery,
                      reason: :connection_closed
                    }},
                   1_000

    assert_receive {:moqx, ^client,
                    %MOQX.Event.DiscoveryDone{discovery: ^discovery, reason: :connection_closed}},
                   1_000

    assert_receive {:moqx, ^client, %MOQX.Event.ConnectionClosed{}}, 1_000
    send(peer.pid, :done)
    Task.await(peer)
  end

  test "raw catalog names and CMSF over Lite remain independently composable" do
    {client, peer} = peer()

    for name <- ["catalog", "catalog.json", ".catalog"] do
      {:ok, raw} =
        MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["room"], track: name}, profile: :none)

      send(peer.pid, {:accept, raw.id})
      assert_receive {:moqx, ^client, %MOQX.Event.SubscriptionAccepted{subscription: ^raw}}, 1_000
      send(peer.pid, {:object, raw.id, 0, "opaque"})

      assert_receive {:moqx, ^client,
                      %MOQX.Event.ObjectReceived{object: %{subscription: ^raw, payload: "opaque"}}},
                     1_000
    end

    for profile <- [:cloudflare_cmsf, :moqtail_cmsf] do
      {:ok, sub} =
        MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["room"], track: "catalog"},
          profile: profile
        )

      send(peer.pid, {:accept, sub.id})
      assert_receive {:moqx, ^client, %MOQX.Event.SubscriptionAccepted{subscription: ^sub}}, 1_000
      send(peer.pid, {:object, sub.id, 0, ~s({"version":1,"tracks":[]})})

      assert_receive {:moqx, ^client,
                      %MOQX.Event.CatalogReceived{subscription: ^sub, catalog: %{tracks: []}}},
                     1_000
    end

    MOQX.close(client)
    send(peer.pid, :done)
    Task.await(peer)
  end

  test "final catalog drains after the subscribe stream finishes before its group arrives" do
    {client, peer} = peer()

    {:ok, sub} =
      MOQX.subscribe(client, %MOQX.TrackRef{namespace: ["room"], track: "catalog.json"},
        profile: :hang
      )

    send(peer.pid, {:accept, sub.id})
    assert_receive {:moqx, ^client, %MOQX.Event.SubscriptionAccepted{subscription: ^sub}}, 1_000
    send(peer.pid, {:finish_subscription, sub.id, 0})
    refute_receive {:moqx, ^client, %MOQX.Event.ProtocolFailed{}}, 50
    send(peer.pid, {:object, sub.id, 0, "{}"})
    assert_receive {:moqx, ^client, %MOQX.Event.CatalogReceived{subscription: ^sub}}, 1_000
    assert_receive {:moqx, ^client, %MOQX.Event.SubscriptionDone{subscription: ^sub}}, 1_000
    MOQX.close(client)
    send(peer.pid, :done)
    Task.await(peer)
  end

  defp peer, do: MOQX.ProfilePeer.start()
end
