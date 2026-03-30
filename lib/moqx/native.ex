defmodule MOQX.Native do
  use Rustler, otp_app: :moqx, crate: "moqx_native"

  def connect(_url), do: :erlang.nif_error(:nif_not_loaded)
  def session_version(_session), do: :erlang.nif_error(:nif_not_loaded)
  def session_close(_session), do: :erlang.nif_error(:nif_not_loaded)
end
