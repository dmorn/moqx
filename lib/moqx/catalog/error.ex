defmodule MOQX.Catalog.Error do
  @moduledoc "A typed catalog validation error with a path to the invalid field."

  @enforce_keys [:path, :reason]
  defexception [:path, :reason, :value]

  @type reason ::
          :required
          | :invalid_type
          | :invalid_base64
          | :out_of_range
          | :unsupported
          | :invalid_json
          | :invalid_shape

  @type t :: %__MODULE__{
          path: [atom() | non_neg_integer()],
          reason: reason(),
          value: term()
        }

  @impl true
  def message(%__MODULE__{path: path, reason: reason}) do
    "invalid catalog field #{inspect(path)}: #{reason}"
  end
end
