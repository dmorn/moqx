defmodule MOQX.Protocol.MOQTDraft14.Messages.ClientSetup do
  @moduledoc "MOQT draft-14 CLIENT_SETUP message."
  defstruct versions: [], params: %{}
end

defmodule MOQX.Protocol.MOQTDraft14.Messages.ServerSetup do
  @moduledoc "MOQT draft-14 SERVER_SETUP message."
  defstruct [:selected_version, params: %{}]
end

defmodule MOQX.Protocol.MOQTDraft14.Messages.Subscribe do
  @moduledoc "MOQT draft-14 SUBSCRIBE message."

  defstruct [
    :request_id,
    :track_namespace,
    :track_name,
    subscriber_priority: 127,
    group_order: :publisher,
    forward: true,
    filter_type: :largest_object,
    params: %{}
  ]
end

defmodule MOQX.Protocol.MOQTDraft14.Messages.SubscribeOk do
  @moduledoc "MOQT draft-14 SUBSCRIBE_OK message."
  defstruct [:request_id, :track_alias, :expires, :group_order, :largest_location, params: %{}]
end

defmodule MOQX.Protocol.MOQTDraft14.Messages.SubscribeError do
  @moduledoc "MOQT draft-14 SUBSCRIBE_ERROR message."
  defstruct [:request_id, :error_code, :reason_phrase]
end

defmodule MOQX.Protocol.MOQTDraft14.Messages.Unsubscribe do
  @moduledoc "MOQT draft-14 UNSUBSCRIBE message."
  defstruct [:request_id]
end

defmodule MOQX.Protocol.MOQTDraft14.Messages.SubgroupObject do
  @moduledoc "One object decoded from a MOQT draft-14 subgroup stream."

  defstruct [
    :type,
    :track_alias,
    :group_id,
    :subgroup_id,
    :priority,
    :object_id,
    :status,
    :payload
  ]
end

defmodule MOQX.Protocol.MOQTDraft14.Messages.SubgroupHeader do
  @moduledoc "MOQT draft-14 subgroup stream header."
  defstruct [:type, :track_alias, :group_id, :subgroup_id, :publisher_priority]
end
