defmodule MOQX.Codec.EncoderDecoderTest do
  use ExUnit.Case, async: true

  alias MOQX.Codec.{Decoder, Encoder}
  alias MOQX.MOQLite04

  defmodule FrameDecoder do
    @behaviour Decoder

    @impl true
    def decode(payload, _context) when is_binary(payload) do
      {:ok, %MOQLite04.Frame{payload: payload}}
    end
  end

  describe "encoder protocol" do
    test "passes byte-aligned binaries through as payload iodata" do
      assert Encoder.encode("payload") == "payload"
    end

    test "encodes lists by recursively encoding their values" do
      assert Encoder.encode(["moq", "-", ["lite", "-04"]]) == ["moq", "-", ["lite", "-04"]]
    end
  end

  describe "decoder behaviour" do
    test "lets concrete decoders return typed values" do
      assert FrameDecoder.decode("payload", %{stream_type: :group}) ==
               {:ok, %MOQLite04.Frame{payload: "payload"}}
    end
  end
end
