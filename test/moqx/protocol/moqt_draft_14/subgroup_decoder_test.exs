defmodule MOQX.Protocol.MOQTDraft14.SubgroupDecoderTest do
  use ExUnit.Case, async: true

  alias MOQX.Protocol.MOQTDraft14.Messages.SubgroupObject
  alias MOQX.Protocol.MOQTDraft14.SubgroupDecoder

  test "incrementally decodes multiple objects and terminal status" do
    bytes = <<0x15, 2, 5, 0, 7, 0, 0, 3, "abc", 1, 0, 0, 3>>

    {_decoder, objects} =
      bytes
      |> :binary.bin_to_list()
      |> Enum.reduce({%SubgroupDecoder{}, []}, fn byte, {decoder, objects} ->
        assert {:ok, decoder, decoded} = SubgroupDecoder.push(decoder, <<byte>>)
        {decoder, objects ++ decoded}
      end)

    assert [
             %SubgroupObject{
               track_alias: 2,
               group_id: 5,
               subgroup_id: 0,
               priority: 7,
               object_id: 0,
               status: nil,
               payload: "abc"
             },
             %SubgroupObject{
               track_alias: 2,
               group_id: 5,
               object_id: 1,
               status: :end_of_group,
               payload: <<>>
             }
           ] = objects
  end
end
