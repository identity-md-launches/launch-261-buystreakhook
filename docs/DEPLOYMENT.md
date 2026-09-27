# Deployment handoff

## Approved immutable parameters

| Parameter | Value |
| --- | --- |
| Network | Sepolia, chain ID 11155111 only |
| Token artifact | `src/STREAK.sol:STREAK` |
| Token constructor | No arguments; 1,000,000,000 × 10^18 minted to `msg.sender` |
| Hook artifact | `src/BuyStreakHook.sol:BuyStreakHook` |
| Hook constructor | Exactly one ABI-encoded address, the PoolManager |
| Sepolia PoolManager from approved workflow | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| Address permission mask | `(uint160(hook) & 0x3fff) == 0x00cc` |
| Pool key | currency0 = native ETH (zero); currency1 = deployed STREAK; fee = 3000; tickSpacing = 60; hooks = deployed hook |
| Compiler | 0.8.26, Cancun, optimizer enabled / 200 runs, bytecode_hash = none |
| Fee constants | 100 bps base, 10 bps per effective day, 30 bps floor |
| Calendar / minimum buy | UTC days of 86,400 seconds / 0.0005 ETH |
| Fee destination | `0x000000000000000000000000000000000000dEaD` |

The constructor checks permissions through `Hooks.validateHookPermissions`; there is no
test bypass, address etching, or permission override in deployment. The token address is
learned from each pool key, not passed as another constructor argument. Deployment chain
selection is a service responsibility; the contracts themselves are usable with a local
manager for deterministic tests.

## Concrete rehearsal assumptions for the manifest author

The supplied workflow fixes the pool key and requires token-only seeding, but supplies
**no numeric initialization price, seed allocation, factory source/address, LP custody,
or final manifest**. This suite uses the following explicit proposed parameters:

| Rehearsal parameter | Value |
| --- | --- |
| Initial STREAK per ETH | 100,000,000, using equal 18-decimal units |
| `sqrtPriceX96` | `792281625142643375935439503360000` (= 10,000 × 2^96) |
| Seed token budget | Entire 1,000,000,000 STREAK supply, subject to liquidity rounding |
| Seed tick range | `[-887220, 184200]`, both multiples of 60 |
| ETH seed | Exactly 0 |
| Liquidity | `floor(tokenBudget * 2^96 / (sqrtPriceAtTick(184200) - sqrtPriceAtTick(-887220)))` |
| Position salt | Zero |
| Rehearsal LP owner | `test/fixtures/LaunchFactory.sol` |

The initial price is above the range's upper boundary, so the seed requires currency1
only. A buy first crosses into this range and adds the pool's first ETH. The fixture checks
the seed's actual ETH delta is zero, its token debt is settled, its mint belongs to the
factory, and the first buy succeeds. It does not pre-fund ETH, inject runtime code, or mock
swap accounting. Liquidity rounding can leave token dust at the factory.

These are reviewable rehearsal values, **not a claim that an absent manifest or live factory
already uses them**. The manifest author should adopt them or supply approved alternatives;
the service must rerun the rehearsal with the final manifest price, allocation, tick range,
and actual factory path before release. No `launch.json` is authored by this source assignment.

## CREATE2 and factory sequence

1. Build the exact compiler artifacts. Construct hook init code as creation bytecode followed
   by `abi.encode(IPoolManager(sepoliaManager))`.
2. Mine a salt against the **actual CREATE2 deployer** (which may differ from the service
   caller): `address(uint160(uint256(keccak256(0xff ++ deployer ++ salt ++ keccak256(initCode)))))`.
   Require the low 14 bits to equal `0x00CC` and the address to be unoccupied. Any source,
   compiler, constructor, or deployer change requires remining. The local pure mining helper
   is `test/fixtures/HookMiner.sol`; its search cap is 200,000 candidates.
3. Deploy STREAK from the factory and verify it owns the full supply. Deploy the hook with
   the mined salt and single manager argument; compare its declared permissions and address.
4. Initialize the static-fee pool at the reviewed price. In an unlock, add the token-only
   position and settle STREAK via `sync(token) -> transfer(token) -> settle()`. There is no
   init/liquidity hook permission to block this sequence.
5. Verify the resulting PoolId, initial price, seed deltas, hook runtime, and claims balance.
   Exercise the first buy using valid EOA hookData. Settle router debts within its unlock;
   return deltas alone do not transfer the swapper's funds.

## Responsibilities after this contribution

- The manifest contributor writes only `launch.json`; an independent contributor reviews
  accepted source and the concrete manifest for constructor, authorization, and parameter
  conflicts. This source contribution is not that independent review.
- Services handle source publication, signed artifact/attestation linkage, policy admission,
  CREATE2 deployment, and on-chain verification. Policy and signed artifact linkage belong
  to those services, not to a hook admin or a source-generated manifest.
- The launch operator reconciles the actual factory split/LP custody, price and ticks with
  the final manifest; verifies Sepolia chain and canonical manager runtime; and runs the
  real-factory/fork rehearsal. No network deployment or funded-wallet transaction is made here.
- Anyone may operate a fee-burning keeper. It calls `burnFees()` in a separate transaction,
  pays gas, and receives no reward. Failed payouts leave claims intact and can be retried.
- The later static frontend contribution uses the live pool, hook ABI, and designated
  Sepolia router, passes `abi.encode(connectedWallet)`, quotes from the views, and indexes
  `StreakUpdated` for the 30-day calendar. Its approved label is `lab-streak-hook` and its
  static export entrypoint is `dist/index.html`. Addresses and event start blocks must come
  from the completed service deployment. Users need price limits appropriate to each trade;
  hitting one partially reverts rather than silently reducing their specified amount.
