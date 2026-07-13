defmodule MOQX.CMAFPublisherTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "splits initialization data from complete moof fragments", %{tmp_dir: tmp_dir} do
    init = box("ftyp", "brand") <> box("moov", "metadata")
    fragment_0 = box("moof", "fragment-0") <> box("mdat", "payload-0")
    fragment_1 = box("moof", "fragment-1") <> box("mdat", "payload-1")
    path = Path.join(tmp_dir, "sample.mp4")
    File.write!(path, init <> fragment_0 <> fragment_1)

    assert {:ok, ^init, [^fragment_0, ^fragment_1]} = MOQX.CMAF.read_fragments(path)
  end

  @tag :tmp_dir
  test "rejects a flat or malformed MP4", %{tmp_dir: tmp_dir} do
    flat_path = Path.join(tmp_dir, "flat.mp4")
    File.write!(flat_path, box("ftyp", "brand") <> box("moov", "metadata"))
    assert {:error, :not_fragmented_mp4} = MOQX.CMAF.read_fragments(flat_path)

    malformed_path = Path.join(tmp_dir, "bad.mp4")
    File.write!(malformed_path, <<0, 0, 0, 100, "moof", 1, 2, 3>>)
    assert {:error, :invalid_iso_bmff} = MOQX.CMAF.read_fragments(malformed_path)
  end

  defp box(type, payload) do
    <<byte_size(payload) + 8::32, type::binary-size(4), payload::binary>>
  end
end
