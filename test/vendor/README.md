# Vendored test dependencies

These files exist only so the test suite can drive a real Uniswap v4 `PoolManager` offline.
Nothing in `src/` imports them; they are not part of the deployed token.

| Path | Source | Commit / tag | Licence |
| --- | --- | --- | --- |
| `v4-core/src` | https://github.com/Uniswap/v4-core (`src/`, without `src/test`) | `v4.0.0` = `e50237c43811bd9b526eff40f26772152a42daba` | `v4-core/licenses/` (BUSL-1.1 / MIT per file header) |
| `solmate/src/auth/Owned.sol` | https://github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` (the commit v4-core pins) | `solmate/LICENSE` (AGPL-3.0-only) |

One line is changed from upstream, because `remappings.txt` is protected and cannot gain a
`solmate/` remapping:

- `v4-core/src/ProtocolFees.sol` imports `Owned` from `../../solmate/src/auth/Owned.sol`
  instead of `solmate/src/auth/Owned.sol`.

Everything else is byte-for-byte upstream. The project builds v4-core with this repository's
compiler settings (solc 0.8.26, cancun, optimizer 200 runs, no via-ir); upstream builds with
via-ir and 44,444,444 runs, so the bytecode differs from the mainnet deployment but the logic
is the same. The tests construct the manager in place at the mainnet PoolManager address
`0x000000000004444c5dc75cB358380D2e3dE08A90` so the token's balance there is what is asserted.
