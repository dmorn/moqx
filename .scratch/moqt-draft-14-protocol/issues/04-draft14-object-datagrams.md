# Decode draft-14 object datagram delivery

Status: needs-triage
Type: enhancement

## Goal

Add typed object datagram delivery to the shared draft-14 wire package and the
Cloudflare implementation when a deployed path using datagrams is captured.

## Evidence

The public `bbb/.catalog`, `0.mp4`, and `1.m4s` paths observed on 2026-07-13
used subgroup streams, specifically `SubgroupIdExt` (`0x15`). No object
datagram was observed during catalog or 120-object H.264 capture runs.

## Constraints

- preserve the same public `%MOQX.Object{}` coordinates where the datagram
  format provides them;
- retain datagram-specific status and extension metadata;
- add fixed wire vectors plus deployed interop evidence before claiming
  Cloudflare datagram support.

## Comments

- 2026-07-13: Split from the completed subscriber issue because datagram
  delivery was not observed and is not required for the working H.264 path.
