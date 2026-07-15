# GrowYield V6 — Base mainnet (8453)

Deployer: `RELAYER_FACTORY_DEPLOY_PRIVATE_KEY` → `0xf5C7f897614fDA353a5715594BdB335ED72B7a04`

| Contract | Address |
|---|---|
| GrowYieldRegistryV6 | `0x7F219F5009Df002307Cf759994a1370De3d089E0` |
| GrowYieldExecutorV6 | `0x4Ac4BE21D3E285DD3A6c6e9B908fc84aC3E72306` |
| GrowYieldValidatorV6 | `0x20620365B8173FF9973E6332240c167747179DFe` |
| GrowYieldPolicyHookV6 | `0x7e1C39F23Bea34A1e7e8de22fEbA8D7B79497505` |
| TestMorphoVaultEligibility | `0x006A9c616E87F10635896D3B16D1E6922B5Ace16` |

Configured:

| Item | Address |
|---|---|
| Asset (USDC) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Morpho child (Steakhouse Prime USDC) | `0xbeef0e0834849aCC03f0089F01f4F1Eeb06873C9` |
| Morpho fee wrapper | `0xe7Ff051e056edC80C35cDFA2EFBB6396f7dFb4Bd` |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| aUSDC | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |

## MA v2 install (Alchemy bundler)

| Field | Value |
|---|---|
| Smart account | `0x68f1ac3B164519EA9cb66418216D548C39283021` |
| Owner EOA | `0x96940841C3D3cF1fC7a8d8B437618bcd76765cEb` |
| Automation signer | `0x5F6694c633DfB3f8Dc46791CF34A70643515422D` |
| Install UserOp | `0x952314a2b69f5890711139987cbf9658811b7af82adbe2712832ed0ff7cf86e0` |
| Status | confirmed |

Installed: `GrowYieldValidatorV6` (entityId 1) + `GrowYieldPolicyHookV6` exec pre-hook on `executeBatch` in one owner-signed UserOp.

## Live yield ops (automation-signed, Alchemy bundler)

| Op | UserOp | Tx |
|---|---|---|
| `depositAll` → Aave | `0x134fca4fb2cbc4e438c1030eb9c1e56982ef18f26d574bf4ef3ed8a4325ad4b9` | `0x760b06c07b302f9e1a7d3f56d524d1cd3234a5efe8b415c0127c059622846d74` |
| `reallocateAll` Aave → Morpho | `0xf9a28a2697425dee3eb7c41c5c04031efb8905e17f1cb4f76299b4acda5bf3c4` | `0x0468d110728ab0063fa9d050225243538ab7d40623b83d7792b8bf29b350179d` |
| `withdrawAll` Morpho | `0x84fa753129db9bee842b651c798ed7506708bc034034c5272fba9278a915cdfb` | `0x6c998433bd624a30eae7dc7bcc056ab1f06166e52bef31c326707641cd7be8e7` |

Round-trip of 1 USDC ended at `999998` USDC on the SCW (Aave/Morpho rounding). Positions cleared; executor USDC allowance `0`.

Notes:

- Alchemy RPC hit EIP-7702 in-flight limits for the deployer wallet; contract deploys used `https://mainnet.base.org`.
- Install + yield UserOps used Alchemy gas policy successfully.
- Yield callData must be `executeUserOp`-wrapped (`RequireUserOperationContext` otherwise).
