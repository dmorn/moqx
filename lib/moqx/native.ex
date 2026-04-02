defmodule MOQX.Native do
  @moduledoc false

  use Rustler, otp_app: :moqx, crate: "moqx_native"

  # Connection
  def connect(_url, _role, _tls_verify, _tls_cacertfile),
    do: :erlang.nif_error(:nif_not_loaded)

  def session_version(_session), do: :erlang.nif_error(:nif_not_loaded)
  def session_role(_session), do: :erlang.nif_error(:nif_not_loaded)
  def session_close(_session), do: :erlang.nif_error(:nif_not_loaded)

  # Publish
  def publish(_session, _broadcast_path), do: :erlang.nif_error(:nif_not_loaded)
  def create_track(_broadcast, _track_name), do: :erlang.nif_error(:nif_not_loaded)
  def write_frame(_track, _data), do: :erlang.nif_error(:nif_not_loaded)
  def finish_track(_track), do: :erlang.nif_error(:nif_not_loaded)

  # Subscribe
  def subscribe(_session, _broadcast_path, _track_name), do: :erlang.nif_error(:nif_not_loaded)

  # Fetch
  def fetch(_session, _ref, _namespace, _track_name, _priority, _group_order, _start, _end),
    do: :erlang.nif_error(:nif_not_loaded)
end
