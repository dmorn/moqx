defmodule MOQX.Runtime.ConnectionDriver.StreamEntryTest do
  use ExUnit.Case, async: true

  alias MOQX.Runtime.ConnectionDriver.StreamEntry
  alias MOQX.Transport.Conn.Stream
  alias MOQX.Transport.Conn.Stream.Info

  test "keeps a bidirectional stream addressable after either half closes" do
    entry = StreamEntry.new(stream(send_side?: true, receive_side?: true))

    refute entry |> StreamEntry.close(:receive) |> StreamEntry.terminal?()
    refute entry |> StreamEntry.close(:send) |> StreamEntry.terminal?()
  end

  test "becomes terminal after both halves of a bidirectional stream close" do
    entry = StreamEntry.new(stream(send_side?: true, receive_side?: true))

    assert entry
           |> StreamEntry.close(:receive)
           |> StreamEntry.close(:send)
           |> StreamEntry.terminal?()
  end

  test "starts the unavailable half of a unidirectional stream closed" do
    send_only = StreamEntry.new(stream(send_side?: true, receive_side?: false))
    receive_only = StreamEntry.new(stream(send_side?: false, receive_side?: true))

    assert send_only |> StreamEntry.close(:send) |> StreamEntry.terminal?()
    assert receive_only |> StreamEntry.close(:receive) |> StreamEntry.terminal?()
  end

  test "whole-stream closure terminates both halves" do
    entry = StreamEntry.new(stream(send_side?: true, receive_side?: true))

    assert entry |> StreamEntry.close(:both) |> StreamEntry.terminal?()
  end

  defp stream(sides) do
    %Stream{
      info: %Info{
        stream_id: 4,
        direction: :bidirectional,
        initiator: :local,
        initiator_role: :client,
        local_role: :client,
        send_side?: Keyword.fetch!(sides, :send_side?),
        receive_side?: Keyword.fetch!(sides, :receive_side?)
      }
    }
  end
end
