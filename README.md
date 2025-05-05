# nip07signer

## Usage

Pipe nostr events as JSONL, one per line, to `nip07signer` and it will launch a server, open the browser for you (via your NIP-07 extension) to sign and receive the signed events back. Also outputs JSONL.

```bash
cat test.jsonl | nip07signer
```

## License

MIT