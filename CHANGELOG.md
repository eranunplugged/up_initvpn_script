# Changelog

### [Unreleased] - 2026-07-01
- UNP-8189: bump Reality server Xray-core from v1.8.4 to v26.6.22 (both Ubuntu 20.04 and 24.04 install paths) to match the VPN 2.0 client; drop `minClientVer` from `reality_config.json` so legacy clients can still connect while we evaluate a client-update strategy.
- UNP-8189: parse the new `xray x25519` output format (`PrivateKey:` / `Password (PublicKey):`) in `install_reality.sh` / `install_reality-2404.sh`. v26.6.22 changed the layout, which left `privateKey` empty (xray failed to start) and the client `pbk` empty; extract by label instead of fixed field position.
