defmodule MOQXProbe.Traffic do
  @moduledoc false

  @type workload :: :datagram | :stream
  @type sink :: module()
end
