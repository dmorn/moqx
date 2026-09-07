defmodule MOQX.Profile do
  @moduledoc """
  Application catalog profiles, selected independently of the wire protocol.

  `MOQX.subscribe/3` selects a profile per subscription; omission or `:none`
  delivers opaque objects, including on catalog-named tracks. Explicit CMSF
  profiles work over all three built-in protocols. `:hang` requires Lite05.
  Unsupported compositions fail before opening a stream.

  Profile state belongs to the existing connection driver and to individual
  handles. A malformed catalog emits `MOQX.Event.CatalogFailed` for that
  subscription; other subscriptions and the connection continue.
  """

  @type t :: :none | :cloudflare_cmsf | :moqtail_cmsf | :hang

  @doc "Validates a profile/protocol composition."
  def validate(profile, protocol) do
    cond do
      profile == :none ->
        :ok

      profile in [:cloudflare_cmsf, :moqtail_cmsf] and
          protocol in [:cloudflare_draft_14, :draft_16, :moq_lite_05] ->
        :ok

      profile == :hang and protocol == :moq_lite_05 ->
        :ok

      true ->
        {:error, {:unsupported_profile, profile, protocol}}
    end
  end

  @doc "Returns the conventional catalog track name for a profile and encoding."
  def track_name(:hang, :none), do: {:ok, "catalog.json"}
  def track_name(:hang, :deflate), do: {:ok, "catalog.json.z"}
  def track_name(:cloudflare_cmsf, :none), do: {:ok, ".catalog"}
  def track_name(:moqtail_cmsf, :none), do: {:ok, "catalog"}
  def track_name(_profile, _compression), do: {:error, :unsupported_catalog_encoding}

  @doc false
  def format(:hang), do: :hang
  def format(:cloudflare_cmsf), do: :cloudflare
  def format(:moqtail_cmsf), do: :moqtail_cmsf

  @doc false
  def decode(profile, payload, namespace, options \\ [])

  def decode(:hang, payload, namespace, options),
    do: MOQX.Catalog.decode(payload, [format: :hang, namespace: namespace] ++ options)

  def decode(profile, payload, namespace, options)
      when profile in [:cloudflare_cmsf, :moqtail_cmsf] do
    format = if profile == :cloudflare_cmsf, do: :cloudflare, else: :moqtail_cmsf

    case MOQX.Catalog.decode(payload, [format: format, namespace: namespace] ++ options) do
      {:ok, catalog} -> {:ok, catalog}
      {:error, error} -> {:error, %{error | value: nil}}
    end
  end
end
