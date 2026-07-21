# Adapter deployment matrix (Base fork venues)

Constructor arguments and authenticity results for every venue exercised by the
optional Base fork suites. Factory/Comptroller checks prove **protocol
authenticity** only. Grow approval remains inclusion in the constructor-fixed
registry after a specific `GrowYieldExecutorV3` is chosen.

Chain: **Base (8453)**  
Underlying (all rows): **USDC** `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`  
Executor: **deployment-specific** — pin the `GrowYieldExecutorV3` address being
initialized (not yet recorded on Base for V3; see architecture live-status note).

| Protocol type | Adapter | Venue / market | Position token | Factory or Comptroller | Authenticity check | Result |
|---|---|---|---|---|---|---|
| Aave V3 | `AaveV3Adapter` | USDC reserve via Pool `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` + DataProvider `0x0F43731EB8d45A581f4a36DD74F5f358bc90C73A` | aUSDC `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` | Aave PoolAddressesProvider `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D` (resolves pool + data provider) | `getReserveTokensAddresses(USDC).aToken` non-zero and ≠ USDC; deposit re-checks aToken == pinned | Pass (fork) |
| Morpho Vault V2 | `MorphoVaultV2Adapter` | Grow Smoke Morpho USDC `0xAB03BABdb85C80a77808dD6b2B3ce280cc225014` | same (Vault V2 share) | VaultV2Factory `0x4501125508079A99ebBebCE205DeC9593C2b5857` + MorphoVaultV1AdapterFactory `0xF42D9c36b34c9c2CF3Bc30eD2a52a90eEB604642` | Factory-created wrapper; exactly one factory-created liquidity adapter `0x8Ad255cB4bedE5c91DCCA3721D21821a20e09916`; child `0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183`; matching USDC; empty liquidity data; add/remove adapter selectors abdicated; live gates open | Pass (fork; test-local eligibility admits only the pinned live child) |
| Euler EVK | `EulerEVaultAdapter` | EVault USDC `0x0A1a3b5f2041F33522C4efc754a7D096f880eE16` | same (vault share) | EVK GenericFactory `0x7F321498A801A191a93C840750ed637149dDf8D0` | `factory.isProxy(vault) == true` and `vault.asset() == USDC` | Pass (`isProxy=true`, asset=USDC) |
| Euler Earn | `EulerEarnAdapter` | Earn USDC `0x347005f3C98c3cDEf1B6c6a876608C8a19F88083` | same (vault share) | EulerEarnFactory `0x75F49a2621b6DeC6a5baB22ce961bF3e676EFAE6` | `factory.isVault(vault) == true` and `vault.asset() == USDC` | Pass (`isVault=true`, asset=USDC) |
| CapyFi | `CapyFiAdapter` | caUSDC `0x5aDb71adb317CE975A405e90335068F0aF9F26C7` | same (caToken) | Comptroller / Unitroller `0x00dc4965916e03A734190fA382633657c71f867E` | `caToken.comptroller() == Comptroller`, `markets(caToken).isListed`, `underlying() == USDC` | Pass (listed=true, comptroller match, underlying=USDC) |

The live all-adapter cycle is implemented in
`test/yield/GrowYieldAllAdaptersFork.t.sol`. It deposits into Aave and atomically
rebalances through Morpho V2, Euler EVault, Euler Earn, CapyFi, and back to Aave
using `REDEEM + PREVIOUS_OUTPUT DEPOSIT` at every hop. The test leaves unrelated
idle USDC untouched and finally redeems the position back to USDC.

## Contracts to deploy for first V3 stack (registry not yet initialized)

Because no live `GrowYieldExecutorV3` has called `initializeRegistry` on Base:

| Step | Contract |
|---|---|
| 1 | `GrowYieldExecutorV3(maxLossBps, riskGuardian)` |
| 2 | `GrowYieldPolicyModule` (pins executor + sponsor + gas ceilings) |
| 3 | One immutable adapter per approved venue (pinning the new executor) |
| 4 | `GrowYieldAdapterRegistry(executor, AdapterConfig[])` — complete set |
| 5 | `executor.initializeRegistry(registry)` — once, from `registryInitializer` |

## Halmos clean-HEAD comparison

The three Halmos failures observed after this change also occur on clean
`osiris/improve-execution` HEAD without the adapter work:

```bash
# On clean HEAD (before adapter changes)
halmos --contract GrowYieldHalmosTest
# → 3 passed; 3 failed:
#   check_shortOrGarbageSignature_returnsInvalid
#   check_successfulDeposit_leavesNoResidual
#   check_wrongOuterHash_returnsInvalid

# With adapter changes restored
halmos --contract GrowYieldHalmosTest
# → same 3 passed; same 3 failed (identical counterexample shapes)
```

These failures are therefore pre-existing and outside the Euler/CapyFi adapter
change boundary.
