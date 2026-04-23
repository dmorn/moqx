defmodule MOQX.NativeBinary do
  @moduledoc """
  An object payload that lives in native (Rust) heap until explicitly loaded.

  Received objects normally carry a `%MOQX.NativeBinary{}` as their `payload`
  field instead of a plain Elixir binary. The bytes stay in C space unless one
  of two things happens:

  1. **Loaded into BEAM space** — call `load/1` to obtain a regular `binary()`.
     This is the only moment a copy occurs.

  2. **Passed to another NIF** — hand the `%MOQX.NativeBinary{}` directly to
     `MOQX.write_object/4` or `MOQX.write_datagram/3`. The NIF extracts the
     underlying `Bytes` pointer (O(1) Arc clone) without touching BEAM at all.

  ## Example — zero-copy transcoding loop

      def handle_info({:moqx_object, %MOQX.ObjectReceived{object: obj}}, state) do
        # obj.payload is %MOQX.NativeBinary{} — still on Rust heap
        :ok = MOQX.write_object(state.out_subgroup, obj.object_id, obj.payload)
        {:noreply, state}
      end

  ## Example — load for Elixir-side processing

      def handle_info({:moqx_object, %MOQX.ObjectReceived{object: obj}}, state) do
        bytes = MOQX.NativeBinary.load(obj.payload)
        # bytes is now a regular Elixir binary
        {:noreply, state}
      end

  ## Memory note

  The underlying bytes are reference-counted via Rust's `Arc`. Memory is freed
  when all references — including Elixir variables and in-flight NIF tasks —
  are dropped. BEAM's garbage collector does not account for this memory, so
  avoid accumulating large numbers of unreleased `%MOQX.NativeBinary{}` values.
  """

  @enforce_keys [:ref, :size]
  defstruct [:ref, :size]

  @type t :: %__MODULE__{
          ref: reference(),
          size: non_neg_integer()
        }

  @doc """
  Copies the native bytes into BEAM space, returning a regular `binary()`.

  This is the only operation that allocates BEAM heap for the payload data.
  After this call the BEAM binary and the native buffer exist independently;
  dropping the `%MOQX.NativeBinary{}` frees the native copy.
  """
  @spec load(t()) :: binary()
  def load(%__MODULE__{ref: ref}), do: MOQX.Native.load_native_binary(ref)

  @doc """
  Creates a `%MOQX.NativeBinary{}` by copying an Elixir binary into native heap.

  Useful for testing or when you need a homogeneous payload type regardless of
  the original source. The data is copied once here; subsequent NIF calls on
  the returned value are zero-copy.
  """
  @spec from_binary(binary()) :: t()
  def from_binary(data) when is_binary(data), do: MOQX.Native.make_native_binary(data)
end
