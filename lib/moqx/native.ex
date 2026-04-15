defmodule MOQX.Native do
  @moduledoc false

  use Rustler, otp_app: :moqx, crate: "moqx_native"

  # Connection
  def connect(_url, _role, _tls_verify, _tls_cacertfile, _connect_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  def session_version(_session), do: :erlang.nif_error(:nif_not_loaded)
  def session_role(_session), do: :erlang.nif_error(:nif_not_loaded)
  def session_close(_session), do: :erlang.nif_error(:nif_not_loaded)

  # Publish
  def publish(_session, _broadcast_path, _publish_ref), do: :erlang.nif_error(:nif_not_loaded)
  def create_track(_broadcast, _track_name), do: :erlang.nif_error(:nif_not_loaded)
  def track_next_group_id(_track), do: :erlang.nif_error(:nif_not_loaded)
  def finish_track(_track), do: :erlang.nif_error(:nif_not_loaded)

  # Subgroup send-side primitives
  def open_subgroup(
        _track,
        _group_id,
        _subgroup_id,
        _priority,
        _end_of_group,
        _extensions_present
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def write_object(_subgroup, _object_id, _payload, _extensions, _status),
    do: :erlang.nif_error(:nif_not_loaded)

  def close_subgroup(_subgroup, _emit_end_of_group_marker),
    do: :erlang.nif_error(:nif_not_loaded)

  def flush_subgroup(_subgroup, _flush_ref), do: :erlang.nif_error(:nif_not_loaded)

  # Subscribe
  def subscribe(
        _session,
        _broadcast_path,
        _track_name,
        _delivery_timeout_ms,
        _init_data,
        _track_meta
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  def unsubscribe(_handle), do: :erlang.nif_error(:nif_not_loaded)

  # Fetch
  def fetch(_session, _ref, _namespace, _track_name, _priority, _group_order, _start, _end),
    do: :erlang.nif_error(:nif_not_loaded)
end
