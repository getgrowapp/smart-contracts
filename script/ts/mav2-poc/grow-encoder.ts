/** Alchemy Modular Account v2.0.1 nonce and final-segment encoding. */
export type Hex = `0x${string}`;

export const FINAL_SEGMENT_INDEX = "ff";

/** Selector-associated Grow validation key: `(entityId << 8) | 0`. */
export function growNonceKey(entityId: number): bigint {
  if (!Number.isInteger(entityId) || entityId <= 0 || entityId > 0xffff_ffff) {
    throw new RangeError("Grow entityId must be a nonzero uint32");
  }
  return BigInt(entityId) << 8n;
}

/** Global entity-zero owner validation key used by the pinned MA v2 account. */
export function globalOwnerNonceKey(): bigint {
  return 1n;
}

/** Module payload received by GrowYieldPolicyModule.validateUserOp. */
export function growAuthorization(ecdsaSignature: Hex): Hex {
  const signature = strip0x(ecdsaSignature);
  if (signature.length !== 130) throw new RangeError("ECDSA signature must be 65 bytes");

  return ecdsaSignature;
}

/** Complete UserOperation signature for a Grow validator with no validation hooks. */
export function growUserOpSignature(ecdsaSignature: Hex): Hex {
  return `0x${FINAL_SEGMENT_INDEX}${strip0x(growAuthorization(ecdsaSignature))}`;
}

function strip0x(value: Hex): string {
  return value.slice(2);
}
