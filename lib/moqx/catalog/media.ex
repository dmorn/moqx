defmodule MOQX.Catalog.Media do
  @moduledoc "A HANG audio or video section. Renditions are keyed by exact track name."
  defstruct renditions: %{}, display: nil, rotation: nil, flip: nil, extensions: %{}
  @type t :: %__MODULE__{renditions: %{binary() => MOQX.Catalog.Track.t()}}
end

defmodule MOQX.Catalog.Decoder do
  @moduledoc "Typed WebCodecs configuration. Description contains decoded bytes, never hex text."
  defstruct [
    :codec,
    :description,
    :coded_width,
    :coded_height,
    :display_aspect_width,
    :display_aspect_height,
    :sample_rate,
    :number_of_channels,
    :optimize_for_latency
  ]

  @type t :: %__MODULE__{codec: binary(), description: binary() | nil}
end

defmodule MOQX.Catalog.Container do
  @moduledoc "HANG container metadata. CMAF init contains decoded bytes. Unknown kinds remain explicit."
  defstruct kind: "legacy", init: nil, extensions: %{}
  @type t :: %__MODULE__{kind: binary(), init: binary() | nil, extensions: map()}
end
