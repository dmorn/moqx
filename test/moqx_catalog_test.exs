defmodule MOQX.CatalogTest do
  use ExUnit.Case, async: true

  alias MOQX.Catalog
  alias MOQX.Catalog.Track

  @fixtures_dir Path.join([__DIR__, "support", "fixtures", "catalog"])

  defp fixture(name), do: File.read!(Path.join(@fixtures_dir, name))

  # ---------------------------------------------------------------------------
  # decode/1 — valid payloads
  # ---------------------------------------------------------------------------

  test "decodes a realistic moqtail catalog" do
    assert {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    assert %Catalog{} = catalog
    assert catalog.version == 1
    assert catalog.supports_delta_updates == false
    assert length(catalog.tracks) == 4
  end

  test "decodes a minimal catalog" do
    assert {:ok, catalog} = Catalog.decode(fixture("minimal.json"))
    assert [%Track{name: "t"}] = catalog.tracks
  end

  test "preserves raw map on catalog and tracks" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    assert is_map(catalog.raw)
    assert catalog.raw["generatedAt"] == 1_775_094_299_325

    [video | _] = catalog.tracks
    assert video.raw["width"] == 960
    assert video.raw["height"] == 540
  end

  test "parses track fields correctly" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    video = Catalog.get_track(catalog, "259")
    assert video.role == "video"
    assert video.codec == "avc1.42C01F"
    assert video.packaging == "cmaf"
    assert video.depends == []
    assert video.init_data == nil
  end

  test "base64-decodes initData" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    track = Catalog.get_track(catalog, "260")
    assert track.init_data == Base.decode64!("AAAAGGZ0eXA=")
  end

  test "defaults depends to empty list" do
    {:ok, catalog} = Catalog.decode(fixture("minimal.json"))
    assert hd(catalog.tracks).depends == []
  end

  test "version and supports_delta_updates are nil when absent" do
    {:ok, catalog} = Catalog.decode(fixture("minimal.json"))
    assert catalog.version == nil
    assert catalog.supports_delta_updates == nil
  end

  # ---------------------------------------------------------------------------
  # decode/1 — invalid payloads
  # ---------------------------------------------------------------------------

  test "rejects invalid JSON" do
    assert {:error, "invalid JSON"} = Catalog.decode("not json {")
  end

  test "rejects non-object JSON" do
    assert {:error, "expected a JSON object at the top level"} = Catalog.decode("[1,2,3]")
  end

  test "rejects missing tracks key" do
    assert {:error, "missing required \"tracks\" key"} = Catalog.decode(~s({"version":1}))
  end

  test "rejects tracks that is not a list" do
    assert {:error, "\"tracks\" must be a list"} = Catalog.decode(~s({"tracks":"bad"}))
  end

  test "rejects track without name" do
    payload = ~s({"tracks":[{"role":"video"}]})
    assert {:error, "track entry missing required \"name\" field"} = Catalog.decode(payload)
  end

  test "rejects track with non-string name" do
    payload = ~s({"tracks":[{"name":123}]})
    assert {:error, "track name must be a string, got: 123"} = Catalog.decode(payload)
  end

  test "rejects track with invalid base64 initData" do
    payload = ~s({"tracks":[{"name":"t","initData":"!!!not-base64"}]})
    assert {:error, msg} = Catalog.decode(payload)
    assert msg =~ "invalid base64"
  end

  # ---------------------------------------------------------------------------
  # decode!/1
  # ---------------------------------------------------------------------------

  test "decode!/1 returns catalog on valid input" do
    assert %Catalog{} = Catalog.decode!(fixture("moqtail.json"))
  end

  test "decode!/1 raises on invalid input" do
    assert_raise ArgumentError, ~r/failed to decode CMSF catalog/, fn ->
      Catalog.decode!("bad")
    end
  end

  # ---------------------------------------------------------------------------
  # Discovery helpers
  # ---------------------------------------------------------------------------

  test "tracks/1 returns all tracks" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    assert length(Catalog.tracks(catalog)) == 4
  end

  test "get_track/2 finds by name" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    assert %Track{name: "261", role: "audio"} = Catalog.get_track(catalog, "261")
  end

  test "get_track/2 returns nil for missing name" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    assert Catalog.get_track(catalog, "nonexistent") == nil
  end

  test "tracks_by_role/2 filters correctly" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    videos = Catalog.tracks_by_role(catalog, "video")
    assert length(videos) == 2
    assert Enum.all?(videos, &(&1.role == "video"))
  end

  test "video_tracks/1 returns video tracks" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    assert length(Catalog.video_tracks(catalog)) == 2
  end

  test "audio_tracks/1 returns audio tracks" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    audios = Catalog.audio_tracks(catalog)
    assert length(audios) == 1
    assert hd(audios).name == "261"
  end

  test "tracks_by_role/2 returns empty list for unknown role" do
    {:ok, catalog} = Catalog.decode(fixture("moqtail.json"))
    assert Catalog.tracks_by_role(catalog, "subtitle") == []
  end

  # ---------------------------------------------------------------------------
  # await_catalog/2
  # ---------------------------------------------------------------------------

  test "await_catalog/2 collects objects and decodes" do
    ref = make_ref()
    payload = fixture("moqtail.json")

    spawn(fn ->
      send(self(), {:moqx_fetch_started, ref, "moqtail", "catalog"})
      send(self(), {:moqx_fetch_object, ref, 0, 0, payload})
      send(self(), {:moqx_fetch_done, ref})
    end)

    # Messages are sent to self() inside the spawned process, so send them
    # directly to the test process instead.
    send(self(), {:moqx_fetch_started, ref, "moqtail", "catalog"})
    send(self(), {:moqx_fetch_object, ref, 0, 0, payload})
    send(self(), {:moqx_fetch_done, ref})

    assert {:ok, %Catalog{}} = MOQX.await_catalog(ref, 1_000)
  end

  test "await_catalog/2 concatenates multiple objects" do
    ref = make_ref()
    full = fixture("moqtail.json")
    # Split the payload roughly in half
    mid = div(byte_size(full), 2)
    <<part1::binary-size(mid), part2::binary>> = full

    send(self(), {:moqx_fetch_started, ref, "ns", "catalog"})
    send(self(), {:moqx_fetch_object, ref, 0, 0, part1})
    send(self(), {:moqx_fetch_object, ref, 0, 1, part2})
    send(self(), {:moqx_fetch_done, ref})

    assert {:ok, %Catalog{}} = MOQX.await_catalog(ref, 1_000)
  end

  test "await_catalog/2 returns error on fetch error" do
    ref = make_ref()
    send(self(), {:moqx_fetch_error, ref, "relay rejected"})
    assert {:error, "relay rejected"} = MOQX.await_catalog(ref, 1_000)
  end

  test "await_catalog/2 returns error on timeout" do
    ref = make_ref()
    assert {:error, "timeout"} = MOQX.await_catalog(ref, 50)
  end

  test "await_catalog/2 returns decode error on bad payload" do
    ref = make_ref()
    send(self(), {:moqx_fetch_object, ref, 0, 0, "not json"})
    send(self(), {:moqx_fetch_done, ref})
    assert {:error, "invalid JSON"} = MOQX.await_catalog(ref, 1_000)
  end
end
