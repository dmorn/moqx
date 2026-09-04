use std::fmt::Write;

use anyhow::Context;
use clap::Parser;
use moq_net::*;

#[derive(Parser)]
struct Config {
    #[arg(long)]
    broadcast: String,

    #[arg(long)]
    track: String,

    #[command(flatten)]
    client: moq_native::ClientConfig,

    #[command(flatten)]
    log: moq_native::Log,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = Config::parse();
    config.log.init()?;

    let url = config
        .client
        .connect
        .clone()
        .context("--client-connect is required")?;
    let client = config.client.init()?;
    let origin = Origin::random().produce();
    let reconnect = client.with_subscriber(origin.clone()).reconnect(url);

    tokio::select! {
        result = receive_one(origin, &config.broadcast, &config.track) => result,
        result = reconnect.closed() => {
            result?;
            anyhow::bail!("connection closed before one frame arrived")
        }
    }
}

async fn receive_one(origin: origin::Producer, broadcast: &str, track: &str) -> anyhow::Result<()> {
    let path: Path<'_> = broadcast.into();
    let mut announced = origin
        .scope(&[path])
        .context("broadcast path is outside the consumer scope")?
        .consume()
        .announced();

    let broadcast = loop {
        let update = announced
            .next()
            .await
            .context("origin closed before broadcast announcement")?;
        if let Some(broadcast) = update.broadcast {
            break broadcast;
        }
    };

    let mut track = broadcast.track(track)?.subscribe(None).await?;
    let mut group = track
        .recv_group()
        .await?
        .context("track ended before one group arrived")?;
    let frame = group
        .read_frame()
        .await?
        .context("group ended before one frame arrived")?;
    let mut payload_hex = String::with_capacity(frame.payload.len() * 2);

    for byte in frame.payload {
        write!(&mut payload_hex, "{byte:02x}")?;
    }

    println!(
        "group={} timestamp_us={} payload_hex={payload_hex}",
        group.sequence,
        frame.timestamp.as_micros()
    );

    Ok(())
}
