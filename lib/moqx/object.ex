defmodule MOQX.Object do
  @moduledoc """
  A single MoQ object delivered to a subscriber.

  Each `t:t/0` corresponds to one object as defined by the MoQ transport
  specification: a single element within a subgroup stream (or, in a future
  release, a datagram — see issue #13).

  Pattern-match on the fields you care about:

      receive do
        {:moqx_object, ^sub,
         %MOQX.Object{group_id: g, subgroup_id: sg, object_id: o, payload: p}} ->
          handle(g, sg, o, p)
      end

  ## Fields

    * `:group_id` — the group this object belongs to
    * `:subgroup_id` — the resolved subgroup id. Always a concrete integer on
      receive; for publishers that use the "subgroup id = first object id" mode
      the value is derived from the first object's id
    * `:object_id` — the object's id within the subgroup
    * `:priority` — publisher priority (`0..255`) carried in the subgroup header
    * `:status` — `:normal` for data-bearing objects, otherwise a marker status
      (`:does_not_exist`, `:end_of_group`, `:end_of_track`)
    * `:extensions` — list of `{type, value}` extension headers.
      Even `type` carries a varint value (non-negative integer); odd `type`
      carries a binary value. This parity rule is enforced by the MoQ spec
    * `:payload` — object payload bytes. Empty binary for marker statuses
  """

  @enforce_keys [:group_id, :subgroup_id, :object_id, :priority, :status, :payload]
  defstruct [:group_id, :subgroup_id, :object_id, :priority, :status, :payload, extensions: []]

  @type status :: :normal | :does_not_exist | :end_of_group | :end_of_track

  @type extension :: {non_neg_integer(), non_neg_integer() | binary()}

  @type t :: %__MODULE__{
          group_id: non_neg_integer(),
          subgroup_id: non_neg_integer(),
          object_id: non_neg_integer(),
          priority: 0..255,
          status: status(),
          extensions: [extension()],
          payload: binary()
        }
end
