defmodule MOQX.Codec.BinaryTest do
  use ExUnit.Case, async: true

  alias MOQX.Codec

  describe "variable-length integers" do
    test "encodes and decodes QUIC variable-length integer samples" do
      assert Codec.encode_varint(37) == <<0x25>>
      assert Codec.decode_varint(<<0x25, "rest">>) == {:ok, 37, "rest"}
    end

    test "uses the shortest QUIC variable-length integer size class" do
      assert Codec.encode_varint(63) == <<0x3F>>
      assert Codec.encode_varint(64) == <<0b01::2, 64::14>>
      assert Codec.encode_varint(16_383) == <<0b01::2, 16_383::14>>
      assert Codec.encode_varint(16_384) == <<0b10::2, 16_384::30>>
      assert Codec.encode_varint(1_073_741_823) == <<0b10::2, 1_073_741_823::30>>
      assert Codec.encode_varint(1_073_741_824) == <<0b11::2, 1_073_741_824::62>>

      assert Codec.encode_varint(4_611_686_018_427_387_903) ==
               <<0b11::2, 4_611_686_018_427_387_903::62>>
    end

    test "decodes every QUIC variable-length integer size class" do
      assert Codec.decode_varint(<<0x40, 0x25, "rest">>) == {:ok, 37, "rest"}
      assert Codec.decode_varint(<<0x7B, 0xBD, "rest">>) == {:ok, 15_293, "rest"}

      assert Codec.decode_varint(<<0x9D, 0x7F, 0x3E, 0x7D, "rest">>) ==
               {:ok, 494_878_333, "rest"}

      assert Codec.decode_varint(<<0xC2, 0x19, 0x7C, 0x5E, 0xFF, 0x14, 0xE8, 0x8C, "rest">>) ==
               {:ok, 151_288_809_941_952_652, "rest"}
    end

    test "reports incomplete QUIC variable-length integer inputs" do
      assert Codec.decode_varint(<<>>) == {:error, :incomplete}
      assert Codec.decode_varint(<<0b01::2, 1::6>>) == {:error, :incomplete}
      assert Codec.decode_varint(<<0b10::2, 1::6, 0>>) == {:error, :incomplete}
      assert Codec.decode_varint(<<0b11::2, 1::6, 0, 0, 0>>) == {:error, :incomplete}
    end
  end

  describe "length-prefixed strings" do
    test "encodes and decodes UTF-8 strings with a varint byte length prefix" do
      assert Codec.encode_string("moq") == <<3, "moq">>
      assert Codec.decode_string(<<3, "moq", "rest">>) == {:ok, "moq", "rest"}
    end

    test "reports malformed string payloads" do
      assert Codec.decode_string(<<5, "moq">>) == {:error, :incomplete}
      assert Codec.decode_string(<<1, 0xFF>>) == {:error, :invalid_utf8}
    end
  end

  describe "length-prefixed bytes" do
    test "encodes and decodes opaque bytes with a varint byte length prefix" do
      assert Codec.encode_bytes(<<0, 1, 2>>) == <<3, 0, 1, 2>>
      assert Codec.decode_bytes(<<3, 0, 1, 2, "rest">>) == {:ok, <<0, 1, 2>>, "rest"}
    end

    test "reports malformed byte payloads" do
      assert Codec.decode_bytes(<<4, 0, 1>>) == {:error, :incomplete}
    end
  end
end
