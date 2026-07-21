# Alchemy Modular Account v2.0.1 encoder notes

The previous scripts encoded the retired `SingleSigner -> EIP-1271` beta path and
were removed. They cannot authorize `GrowYieldPolicyModule`.

The current reference helpers in [`grow-encoder.ts`](grow-encoder.ts) encode the
pinned account's Grow nonce key and final signature segment. They intentionally do
not implement an account SDK, paymaster negotiation, EIP-712 signing, or the
production multi-owner validator's independent owner signature format.

## Entity and nonce key

Choose a free nonzero `growEntityId` after querying the account's installed
validations. Install Grow as selector-associated UserOperation validation for
`executeBatch`:

- `isGlobal = false`
- `isSignatureValidation = false`
- `isUserOpValidation = true`
- install data: `abi.encode(growEntityId, address[] initialOwners)`

Pinned Alchemy Modular Account v2.0.1 uses:

```text
global entity-zero owner nonce key = 1
Grow nonce key                    = uint192(growEntityId) << 8
```

Key `1` is entity `0` plus the global option bit. It does not consume, overwrite, or
select entity `1`. If Grow uses entity `1`, its key is `0x100`.

Always obtain the complete nonce from EntryPoint:

```text
entryPoint.getNonce(account, growNonceKey(growEntityId))
```

Do not maintain the 64-bit sequence locally as the source of truth.

## Policy-owner authorization

The module payload is exactly:

```text
bytes65(ECDSA signature)
```

The signature covers:

```text
domain: name="GrowYieldPolicy", version="1", chainId, verifyingContract=module
type:   GrowYieldAuthorization(bytes32 userOpHash)
```

With no Grow validation hooks, Modular Account v2.0.1's complete UserOperation
signature is:

```text
0xFF || bytes65(ECDSA signature)
```

`0xFF` marks the final sparse validation-signature segment. The account removes that
marker and passes the 65-byte remainder to Grow. Do not prepend the retired
SingleSigner EOA/contract-owner discriminator or a module address; the nonce already
selected the validation entity.

## Policy-owner flow

1. Query the installed Grow entity, policy-owner set, adapter policies, pause state,
   and current EntryPoint nonce.
2. Quote each venue independently and build explicit `Operation` values. Use
   `PREVIOUS_OUTPUT` for the destination deposit of a rebalance.
3. Set a nonzero absolute `minAmountOut` for every operation.
4. Construct the canonical approve-max / executor / approve-zero `executeBatch`.
5. Obtain the pinned paymaster data and finalize every gas and fee field.
6. Compute the final EntryPoint `userOpHash`, sign the Grow EIP-712 authorization,
   and apply `growUserOpSignature`.
7. Simulate the final signed operation through the production bundler before submit.
8. Monitor inclusion, consumption, owner revocation, and output; never silently
   loosen a floor or policy in response to a failed simulation.

An account-owner-authorized operation—not the Grow policy—must add/remove policy
owners, set/reset finite adapter policies, or uninstall the Grow validation. The
module does not add an expiry, so unsubmitted signatures remain live while their
nonce is current and their policy owner remains authorized.
