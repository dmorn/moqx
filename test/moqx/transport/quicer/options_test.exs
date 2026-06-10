defmodule MOQX.Transport.Quicer.OptionsTest do
  use ExUnit.Case, async: true

  alias MOQX.Transport.Quicer.Options

  describe "normalize_host/1" do
    test "converts Elixir host strings to charlists" do
      assert Options.normalize_host("relay.example.com") == ~c"relay.example.com"
    end

    test "keeps IP tuple hosts supported" do
      assert Options.normalize_host({127, 0, 0, 1}) == {127, 0, 0, 1}
    end
  end

  describe "normalize_text/1" do
    test "converts textual listener addresses to charlists" do
      assert Options.normalize_text("127.0.0.1:4433") == ~c"127.0.0.1:4433"
    end
  end

  describe "normalize_stream_opts/1" do
    test "maps transport stream direction to quicer open/start flags" do
      assert Options.normalize_stream_opts(direction: :unidirectional) == %{
               active: false,
               quic_event_mask: 1,
               open_flag: 1,
               start_flag: 1
             }
    end

    test "starts bidirectional streams immediately without quicer-only direction metadata" do
      assert Options.normalize_stream_opts(direction: :bidirectional, active: true) == %{
               active: true,
               quic_event_mask: 1,
               open_flag: 0,
               start_flag: 1
             }
    end

    test "preserves transport stream priority for backend application" do
      assert Options.normalize_stream_opts(direction: :unidirectional, priority: 65_535) == %{
               active: false,
               quic_event_mask: 1,
               open_flag: 1,
               priority: 65_535,
               start_flag: 1
             }
    end
  end

  describe "normalize_accept_stream_opts/1" do
    test "defaults accepted streams to passive receive" do
      assert Options.normalize_accept_stream_opts([]) == %{active: false}
    end

    test "preserves explicit active receive mode" do
      assert Options.normalize_accept_stream_opts(active: true) == %{active: true}
    end
  end

  describe "normalize_opts/1" do
    test "converts Elixir ALPN strings to quicer charlists" do
      assert Options.normalize_opts(%{alpn: ["moq-00", "moq-lite-04"]}) == %{
               alpn: [~c"moq-00", ~c"moq-lite-04"]
             }
    end

    test "treats a single binary ALPN as one protocol token" do
      assert Options.normalize_opts(%{alpn: "moq-00"}) == %{alpn: [~c"moq-00"]}
    end

    test "treats a single charlist ALPN as one protocol token" do
      assert Options.normalize_opts(%{alpn: ~c"moq-00"}) == %{alpn: [~c"moq-00"]}
    end

    test "converts certificate path options to charlists" do
      assert Options.normalize_opts(
               cacertfile: ".tmp/integration-certs/ca.pem",
               certfile: ".tmp/integration-certs/server.pem",
               keyfile: ".tmp/integration-certs/server-key.pem"
             ) == %{
               cacertfile: ~c".tmp/integration-certs/ca.pem",
               certfile: ~c".tmp/integration-certs/server.pem",
               keyfile: ~c".tmp/integration-certs/server-key.pem"
             }
    end

    test "does not add ALPN when absent" do
      assert Options.normalize_opts(active: false) == %{active: false}
    end

    test "drops backend-private datagram send flags before calling quicer" do
      assert Options.normalize_opts(alpn: "moq-00", datagram_send_flags: [:dgram_priority]) ==
               %{alpn: [~c"moq-00"]}
    end
  end
end
