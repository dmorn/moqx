defmodule MOQX.Integration.MoqtailDraft16RelayTest do
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :moqtail_draft16_relay

  @relay "moqt://moqtail-draft16-relay:4433"
  @ca_file "/certs/ca.pem"

  test "public subscriber receives an object through the pinned draft-16 relay" do
    assert {:ok, client} =
             MOQX.connect(@relay,
               protocol: :draft_16,
               connect_options: [cacertfile: @ca_file],
               timeout: 5_000
             )

    try do
      track = %MOQX.TrackRef{namespace: ["integration"], track: "video"}
      assert {:ok, subscription} = await_subscription(client, track, 20)

      assert_receive {:moqx, ^client,
                      %MOQX.Event.ObjectReceived{
                        object: %MOQX.Object{
                          subscription: ^subscription,
                          group_id: 0,
                          object_id: 0,
                          payload: payload
                        }
                      }},
                     5_000

      assert byte_size(payload) == 64

      assert_receive {:moqx, ^client,
                      %MOQX.Event.SubgroupEnded{
                        subscription: ^subscription,
                        group_id: 0,
                        outcome: :complete
                      }},
                     5_000
    after
      _result = MOQX.close(client)
    end
  end

  defp await_subscription(_client, _track, 0), do: {:error, :publisher_not_ready}

  defp await_subscription(client, track, attempts) do
    with {:ok, subscription} <- MOQX.subscribe(client, track, start: :next_group) do
      receive do
        {:moqx, ^client, %MOQX.Event.SubscriptionAccepted{subscription: ^subscription}} ->
          {:ok, subscription}

        {:moqx, ^client, %MOQX.Event.SubscriptionFailed{subscription: ^subscription}} ->
          Process.sleep(50)
          await_subscription(client, track, attempts - 1)
      after
        1_000 ->
          {:error, :subscription_response_timeout}
      end
    end
  end
end
