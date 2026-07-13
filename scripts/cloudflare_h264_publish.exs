defmodule MOQX.Scripts.CloudflareH264Publish do
  @moduledoc false

  def run(argv) do
    {options, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          endpoint: :string,
          namespace: :string,
          authorization_file: :string,
          output: :string,
          timeout: :integer
        ]
      )

    with [] <- invalid,
         [input] <- positional,
         endpoint when is_binary(endpoint) <- Keyword.get(options, :endpoint),
         namespace when is_binary(namespace) <- Keyword.get(options, :namespace),
         output when is_binary(output) <- Keyword.get(options, :output),
         {:ok, authorization} <- authorization(options),
         connect_options <- connect_options(endpoint, authorization, options),
         {:ok, publisher} <- MOQX.connect(endpoint, connect_options),
         {:ok, published} <-
           MOQX.CMAF.publish_file(publisher, input,
             namespace: String.split(namespace, "/", trim: true)
           ),
         :ok <- await_publication(publisher, published.publication, connect_options[:timeout]),
         {:ok, subscriber} <- MOQX.connect(endpoint, connect_options),
         {:ok, catalog} <- capture_catalog(subscriber, published, connect_options[:timeout]),
         {:ok, capture} <-
           MOQX.CMAF.capture(subscriber, catalog, output,
             objects: published.fragment_count,
             timeout: connect_options[:timeout]
           ) do
      IO.puts(
        "published and captured #{capture.object_count} fragments (#{capture.media_bytes} media bytes)"
      )

      :ok = MOQX.close(subscriber)
      :ok = MOQX.finish_publication(publisher, published.publication)
      :ok = MOQX.close(publisher)
    else
      [] -> usage()
      nil -> usage()
      [_ | _] -> usage()
      {:error, reason} -> raise "Cloudflare publish smoke failed: #{inspect(reason)}"
    end
  end

  defp authorization(options) do
    case Keyword.get(options, :authorization_file) do
      nil ->
        {:ok, nil}

      path ->
        with {:ok, token} <- File.read(path),
             token <- String.trim(token),
             true <- byte_size(token) > 0 do
          {:ok, MOQX.Secret.new(token)}
        else
          false -> {:error, :empty_authorization_file}
          {:error, reason} -> {:error, {:authorization_file, reason}}
        end
    end
  end

  defp connect_options(endpoint, authorization, options) do
    [
      protocol: :cloudflare_draft_14,
      timeout: Keyword.get(options, :timeout, 15_000),
      endpoint: endpoint
    ]
    |> Keyword.delete(:endpoint)
    |> maybe_authorize(authorization)
  end

  defp maybe_authorize(options, nil), do: options
  defp maybe_authorize(options, authorization), do: Keyword.put(options, :authorization, authorization)

  defp await_publication(client, publication, timeout) do
    receive do
      {:moqx, ^client, {:publication_ready, ^publication}} -> :ok
      {:moqx, ^client, {:publication_error, ^publication, error}} -> {:error, error}
      {:moqx, ^client, {:publication_cancelled, ^publication, error}} -> {:error, error}
      {:moqx, ^client, {:error, reason}} -> {:error, reason}
    after
      timeout -> {:error, :publication_timeout}
    end
  end

  defp capture_catalog(client, published, timeout) do
    track = MOQX.PublishedTrack.track_ref(published.catalog_track)

    with {:ok, subscription} <- MOQX.subscribe(client, track) do
      receive do
        {:moqx, ^client, {:catalog, catalog}} ->
          _result = MOQX.unsubscribe(client, subscription)
          {:ok, catalog}

        {:moqx, ^client, {:subscription_error, ^subscription, error}} ->
          {:error, error}

        {:moqx, ^client, {:error, reason}} ->
          {:error, reason}
      after
        timeout -> {:error, :catalog_timeout}
      end
    end
  end

  defp usage do
    raise """
    usage: mix run scripts/cloudflare_h264_publish.exs INPUT.mp4 \\
      --endpoint moqt://HOST:443 --namespace UNIQUE/NAMESPACE \\
      --output OUTPUT.mp4 [--authorization-file TOKEN_FILE] [--timeout MS]
    """
  end
end

MOQX.Scripts.CloudflareH264Publish.run(System.argv())
