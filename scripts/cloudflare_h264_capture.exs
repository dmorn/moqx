alias MOQX.{CMAF, Catalog, TrackRef}

{output, object_count} =
  case System.argv() do
    [output, count] -> {output, String.to_integer(count)}
    [output] -> {output, 120}
    [] -> {"/tmp/moqx-cloudflare-bbb.mp4", 120}
  end

endpoint = "moqt://draft-14.cloudflare.mediaoverquic.com:443"

{:ok, client} =
  MOQX.connect(endpoint,
    protocol: :cloudflare_draft_14,
    timeout: 10_000
  )

try do
  {:ok, _catalog_subscription} =
    MOQX.subscribe(client, %TrackRef{namespace: ["bbb"], track: ".catalog"})

  catalog =
    receive do
      {:moqx, ^client, {:catalog, %Catalog{} = catalog}} -> catalog
    after
      10_000 -> raise "timed out waiting for Cloudflare catalog"
    end

  {:ok, %CMAF.Capture{} = report} =
    CMAF.capture(client, catalog, output,
      objects: object_count,
      timeout: 30_000
    )

  IO.inspect(report, label: "capture")
after
  _result = MOQX.close(client)
end
