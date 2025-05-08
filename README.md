# nip07_signer

## Usage from the CLI

Pipe nostr events as JSONL, one per line, to `nip07_signer` and it will launch a server, open the browser for you (via your NIP-07 extension) to sign and receive the signed events back. Also outputs JSONL.

```bash
cat test.jsonl | nip07_signer
```

```bash
nak event -c "hello world" | jq 'del(.id,.pubkey,.sig)' | nip07_signer | nak event wss://relay.damus.io
```

(Need to delete signature until `nak` supports partial events)

## Usage as a library

Provides a `Signer` implementation from https://github.com/purplebase/models

## License

MIT