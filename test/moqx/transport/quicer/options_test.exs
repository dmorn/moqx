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

    test "does not add ALPN when absent" do
      assert Options.normalize_opts(active: false) == %{active: false}
    end
  end
end
