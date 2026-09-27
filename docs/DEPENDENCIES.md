# Vendored dependencies

The imported source closure is vendored as ordinary files, with upstream license texts and
SPDX headers preserved. There are no submodules, node modules, runtime package downloads,
or compiler binaries. Tests use local contracts and require no network access.

| Prefix | Upstream / revision |
| --- | --- |
| `v4-core/` | [Uniswap/v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75), `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` |
| `forge-std/` | [foundry-rs/forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505), `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |
| `@openzeppelin/contracts/` | [OpenZeppelin Contracts v5.2.0](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/acd4ff74de833399287ed6b31b4debf6b2b35527), `acd4ff74de833399287ed6b31b4debf6b2b35527` |
| `solmate/` | [transmissions11/solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647), `4b47a19038b798b4a33d9749d25e570443520647` (v4-core's pinned Owned.sol) |

`PINNED.txt` in each dependency records its provenance. Local source files were copied
without modification; unused source files are omitted. v4-core's test routers and
`test/utils/CurrencySettler.sol` support the real-manager integration suite. Dependency
license terms remain upstream's; the project's own contracts, tests, and helper script
are MIT licensed.
