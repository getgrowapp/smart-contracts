/**
 * Automation ops for GrowYield EIP-1271 via Alchemy Account Kit.
 *
 * Outer signature: 0xFF || 0x01 (CONTRACT_OWNER) || abi.encode(Proof)
 * Alchemy MA nonce: (entityId << 8) packed into EP key by the SDK.
 */

import {
  encodeFunctionData,
  encodeAbiParameters,
  concatHex,
  keccak256,
  getAddress,
  type Address,
  type Hex,
  createPublicClient,
  http,
  erc20Abi,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { createModularAccountV2Client } from "@account-kit/smart-contracts";
import { alchemy, base as akBase } from "@account-kit/infra";
import { LocalAccountSigner } from "@aa-sdk/core";
import { config as dotenvConfig } from "dotenv";
import { resolve } from "path";
import { base } from "viem/chains";

dotenvConfig({ path: resolve(__dirname, "../../../../grow-backend/.env") });
dotenvConfig({ path: "/tmp/grow_v6_poc.env" });
dotenvConfig({ path: "/tmp/grow_1271_poc.env" });

const ENTRY_POINT = "0x0000000071727De22E5E9d8BAf0edAc6f37da032" as Address;
const SIG_TYPE_CONTRACT_OWNER = "0x01" as Hex;

const EXECUTE_BATCH_ABI = [
  {
    type: "function",
    name: "executeBatch",
    stateMutability: "payable",
    inputs: [
      {
        name: "calls",
        type: "tuple[]",
        components: [
          { name: "target", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
    ],
    outputs: [{ name: "", type: "bytes[]" }],
  },
] as const;

const EXECUTOR_ABI = [
  {
    type: "function",
    name: "depositAll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "protocol", type: "uint8" },
      { name: "target", type: "address" },
      { name: "asset", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    type: "function",
    name: "withdrawAll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "protocol", type: "uint8" },
      { name: "target", type: "address" },
      { name: "assetHint", type: "address" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "reallocateAll",
    stateMutability: "nonpayable",
    inputs: [
      { name: "sourceProtocol", type: "uint8" },
      { name: "sourceTarget", type: "address" },
      { name: "sourceAssetHint", type: "address" },
      { name: "destinationProtocol", type: "uint8" },
      { name: "destinationTarget", type: "address" },
      { name: "destinationAsset", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
] as const;

enum Protocol {
  MORPHO = 0,
  AAVE = 1,
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

function approveCall(token: Address, spender: Address, amount: bigint) {
  return {
    target: token,
    value: 0n,
    data: encodeFunctionData({
      abi: [
        {
          type: "function",
          name: "approve",
          stateMutability: "nonpayable",
          inputs: [
            { name: "spender", type: "address" },
            { name: "amount", type: "uint256" },
          ],
          outputs: [{ type: "bool" }],
        },
      ],
      functionName: "approve",
      args: [spender, amount],
    }),
  };
}

type PackedFields = {
  sender: Address;
  nonce: bigint;
  initCode: Hex;
  callData: Hex;
  accountGasLimits: Hex;
  preVerificationGas: bigint;
  gasFees: Hex;
  paymasterAndData: Hex;
};

function packUints(high: bigint, low: bigint): Hex {
  return (`0x${((high << 128n) | low).toString(16).padStart(64, "0")}`) as Hex;
}

function asPacked(uo: Record<string, unknown>): PackedFields {
  const sender = uo.sender as Address;
  const nonce = BigInt(uo.nonce as bigint | string | number);
  const callData = uo.callData as Hex;
  const initCode = ((uo.initCode as Hex | undefined) ?? "0x") as Hex;
  let paymasterAndData = ((uo.paymasterAndData as Hex | undefined) ??
    "0x") as Hex;

  if (
    (!paymasterAndData || paymasterAndData === "0x") &&
    uo.paymaster
  ) {
    const pm = getAddress(uo.paymaster as string);
    const pmVerif = BigInt(uo.paymasterVerificationGasLimit as string);
    const pmPost = BigInt(uo.paymasterPostOpGasLimit as string);
    const pmData = ((uo.paymasterData as Hex | undefined) ?? "0x") as Hex;
    paymasterAndData = concatHex([
      pm,
      (`0x${pmVerif.toString(16).padStart(32, "0")}`) as Hex,
      (`0x${pmPost.toString(16).padStart(32, "0")}`) as Hex,
      pmData,
    ]);
  }

  let accountGasLimits = uo.accountGasLimits as Hex | undefined;
  let gasFees = uo.gasFees as Hex | undefined;
  if (!accountGasLimits) {
    accountGasLimits = packUints(
      BigInt(uo.verificationGasLimit as string),
      BigInt(uo.callGasLimit as string),
    );
  }
  if (!gasFees) {
    gasFees = packUints(
      BigInt(uo.maxPriorityFeePerGas as string),
      BigInt(uo.maxFeePerGas as string),
    );
  }

  return {
    sender,
    nonce,
    initCode,
    callData,
    accountGasLimits,
    preVerificationGas: BigInt(uo.preVerificationGas as string),
    gasFees,
    paymasterAndData,
  };
}

function hashUserOp(
  uo: PackedFields,
  chainId: number,
): Hex {
  const packedHash = keccak256(
    encodeAbiParameters(
      [
        { type: "address" },
        { type: "uint256" },
        { type: "bytes32" },
        { type: "bytes32" },
        { type: "bytes32" },
        { type: "uint256" },
        { type: "bytes32" },
        { type: "bytes32" },
      ],
      [
        uo.sender,
        uo.nonce,
        keccak256(uo.initCode),
        keccak256(uo.callData),
        uo.accountGasLimits,
        uo.preVerificationGas,
        uo.gasFees,
        keccak256(uo.paymasterAndData),
      ],
    ),
  );
  return keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "address" }, { type: "uint256" }],
      [packedHash, ENTRY_POINT, BigInt(chainId)],
    ),
  );
}

async function packContractOwnerSig(params: {
  account: PrivateKeyAccount;
  policySigner: Address;
  chainId: number;
  validUntil: number;
  uo: PackedFields;
  userOpHash?: Hex;
}): Promise<Hex> {
  const userOpHash =
    params.userOpHash ?? hashUserOp(params.uo, params.chainId);

  const authSig = await params.account.signTypedData({
    domain: {
      name: "GrowYieldPolicySigner",
      version: "1",
      chainId: params.chainId,
      verifyingContract: params.policySigner,
    },
    types: {
      GrowYieldAuthorization: [
        { name: "userOpHash", type: "bytes32" },
        { name: "validUntil", type: "uint48" },
      ],
    },
    primaryType: "GrowYieldAuthorization",
    message: {
      userOpHash,
      validUntil: params.validUntil,
    },
  });

  const proof = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "version", type: "uint8" },
          { name: "entryPoint", type: "address" },
          { name: "validUntil", type: "uint48" },
          {
            name: "userOp",
            type: "tuple",
            components: [
              { name: "sender", type: "address" },
              { name: "nonce", type: "uint256" },
              { name: "initCode", type: "bytes" },
              { name: "callData", type: "bytes" },
              { name: "accountGasLimits", type: "bytes32" },
              { name: "preVerificationGas", type: "uint256" },
              { name: "gasFees", type: "bytes32" },
              { name: "paymasterAndData", type: "bytes" },
              { name: "signature", type: "bytes" },
            ],
          },
          { name: "signature", type: "bytes" },
        ],
      },
    ],
    [
      {
        version: 1,
        entryPoint: ENTRY_POINT,
        validUntil: params.validUntil,
        userOp: { ...params.uo, signature: "0x" },
        signature: authSig,
      },
    ],
  );

  // MA sparse final segment: 0xFF || SignatureType.CONTRACT_OWNER || proof
  return concatHex(["0xff", SIG_TYPE_CONTRACT_OWNER, proof]);
}

/** Structurally valid proof that returns INVALID (hash mismatch) — no revert. */
function packFailingDummy(callData: Hex, sender: Address): Hex {
  const uo: PackedFields = {
    sender,
    nonce: 0n,
    initCode: "0x",
    callData,
    accountGasLimits: packUints(500_000n, 500_000n),
    preVerificationGas: 100_000n,
    gasFees: packUints(100_000n, 1_000_000n),
    paymasterAndData: "0x",
  };
  const proof = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "version", type: "uint8" },
          { name: "entryPoint", type: "address" },
          { name: "validUntil", type: "uint48" },
          {
            name: "userOp",
            type: "tuple",
            components: [
              { name: "sender", type: "address" },
              { name: "nonce", type: "uint256" },
              { name: "initCode", type: "bytes" },
              { name: "callData", type: "bytes" },
              { name: "accountGasLimits", type: "bytes32" },
              { name: "preVerificationGas", type: "uint256" },
              { name: "gasFees", type: "bytes32" },
              { name: "paymasterAndData", type: "bytes" },
              { name: "signature", type: "bytes" },
            ],
          },
          { name: "signature", type: "bytes" },
        ],
      },
    ],
    [
      {
        version: 1,
        entryPoint: ENTRY_POINT,
        validUntil: Math.floor(Date.now() / 1000) + 3600,
        userOp: { ...uo, signature: "0x" },
        signature: ("0x" + "11".repeat(65)) as Hex,
      },
    ],
  );
  return concatHex(["0xff", SIG_TYPE_CONTRACT_OWNER, proof]);
}

async function main() {
  const apiKey = requireEnv("ALCHEMY_API_KEY");
  const automationPk = (process.env.AUTOMATION_PRIVATE_KEY ||
    process.env.SESSION_KEY_PRIVATE_KEY) as Hex;
  if (!automationPk) throw new Error("Missing automation key");

  const accountAddr = (process.env.ACCOUNT ||
    "0x68f1ac3B164519EA9cb66418216D548C39283021") as Address;
  const executor = getAddress(requireEnv("EXECUTOR"));
  const policySigner = getAddress(requireEnv("POLICY_SIGNER"));
  const policyId =
    process.env.ALCHEMY_GAS_POLICY_ID ||
    process.env.ALCHEMY_GAS_MANAGER_POLICY_ID;
  if (!policyId) throw new Error("Missing ALCHEMY_GAS_POLICY_ID");

  const asset = (process.env.ASSET ||
    "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913") as Address;
  const aavePool = (process.env.AAVE_POOL ||
    "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5") as Address;
  const aToken = (process.env.A_TOKEN ||
    "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB") as Address;
  const morphoWrapper = (process.env.MORPHO_WRAPPER ||
    "0xe7Ff051e056edC80C35cDFA2EFBB6396f7dFb4Bd") as Address;

  const entityId = Number(process.env.ENTITY_ID || 2);
  const op = (process.env.OP || "deposit").toLowerCase();
  const destination = (process.env.DEST || "aave").toLowerCase();
  const validUntil =
    Math.floor(Date.now() / 1000) + Number(process.env.VALID_FOR_SECS || 3600);

  const automation = privateKeyToAccount(automationPk);
  console.log("Automation", automation.address);
  console.log("Account", accountAddr);
  console.log("Op", op, "dest", destination);

  const publicClient = createPublicClient({
    chain: base,
    transport: http(`https://base-mainnet.g.alchemy.com/v2/${apiKey}`),
  });

  const readBal = async () => ({
    usdc: (
      await publicClient.readContract({
        address: asset,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [accountAddr],
      })
    ).toString(),
    aToken: (
      await publicClient.readContract({
        address: aToken,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [accountAddr],
      })
    ).toString(),
    wrapper: (
      await publicClient.readContract({
        address: morphoWrapper,
        abi: erc20Abi,
        functionName: "balanceOf",
        args: [accountAddr],
      })
    ).toString(),
  });
  console.log("balances before", await readBal());

  let calls;
  if (op === "deposit") {
    const target = destination === "morpho" ? morphoWrapper : aavePool;
    const protocol =
      destination === "morpho" ? Protocol.MORPHO : Protocol.AAVE;
    calls = [
      approveCall(asset, executor, 2n ** 256n - 1n),
      {
        target: executor,
        value: 0n,
        data: encodeFunctionData({
          abi: EXECUTOR_ABI,
          functionName: "depositAll",
          args: [protocol, target, asset],
        }),
      },
      approveCall(asset, executor, 0n),
    ];
  } else if (op === "withdraw") {
    if (destination === "morpho") {
      calls = [
        approveCall(morphoWrapper, executor, 2n ** 256n - 1n),
        {
          target: executor,
          value: 0n,
          data: encodeFunctionData({
            abi: EXECUTOR_ABI,
            functionName: "withdrawAll",
            args: [Protocol.MORPHO, morphoWrapper, asset],
          }),
        },
        approveCall(morphoWrapper, executor, 0n),
      ];
    } else {
      calls = [
        approveCall(aToken, executor, 2n ** 256n - 1n),
        {
          target: executor,
          value: 0n,
          data: encodeFunctionData({
            abi: EXECUTOR_ABI,
            functionName: "withdrawAll",
            args: [Protocol.AAVE, aavePool, asset],
          }),
        },
        approveCall(aToken, executor, 0n),
      ];
    }
  } else if (op === "reallocate") {
    calls = [
      approveCall(aToken, executor, 2n ** 256n - 1n),
      {
        target: executor,
        value: 0n,
        data: encodeFunctionData({
          abi: EXECUTOR_ABI,
          functionName: "reallocateAll",
          args: [
            Protocol.AAVE,
            aavePool,
            asset,
            Protocol.MORPHO,
            morphoWrapper,
            asset,
          ],
        }),
      },
      approveCall(aToken, executor, 0n),
    ];
  } else {
    throw new Error(`Unknown OP=${op}`);
  }

  const callData = encodeFunctionData({
    abi: EXECUTE_BATCH_ABI,
    functionName: "executeBatch",
    args: [calls],
  });

  let latestUo: PackedFields | null = null;

  const client = await createModularAccountV2Client({
    chain: akBase,
    transport: alchemy({ apiKey }),
    signer: LocalAccountSigner.privateKeyToAccountSigner(automationPk),
    accountAddress: accountAddr,
    signerEntity: {
      entityId,
      isGlobalValidation: false,
    },
    policyId,
  });

  client.account.getDummySignature = (() =>
    packFailingDummy(callData, accountAddr)) as typeof client.account
    .getDummySignature;

  client.account.signUserOperationHash = (async (uoHash: Hex) => {
    if (!latestUo) throw new Error("UO not captured");
    const expected = hashUserOp(latestUo, base.id);
    if (expected.toLowerCase() !== uoHash.toLowerCase()) {
      console.warn("hash mismatch", { expected, uoHash });
    }
    return packContractOwnerSig({
      account: automation,
      policySigner,
      chainId: base.id,
      validUntil,
      uo: latestUo,
      userOpHash: uoHash,
    });
  }) as typeof client.account.signUserOperationHash;

  // Capture finalized UO fields just before signing via middleware hook.
  const anyClient = client as unknown as {
    middleware: {
      signUserOperation?: (
        struct: Record<string, unknown>,
        args: unknown,
      ) => Promise<Record<string, unknown>>;
    };
    buildUserOperation: (args: { uo: Hex }) => Promise<Record<string, unknown>>;
    sendRawUserOperation: (args: {
      uo: Record<string, unknown>;
    }) => Promise<{ hash: Hex }>;
    waitForUserOperationTransaction: (args: {
      hash: Hex;
    }) => Promise<Hex>;
    sendUserOperation: (args: { uo: Hex }) => Promise<{ hash: Hex }>;
  };

  const prevSign = anyClient.middleware.signUserOperation?.bind(
    anyClient.middleware,
  );
  if (prevSign) {
    anyClient.middleware.signUserOperation = async (struct, args) => {
      latestUo = asPacked(struct);
      console.log("captured UO nonce", latestUo.nonce.toString());
      return prevSign(struct, args);
    };
  }

  console.log("Building UserOp (dummy 1271 proof returns INVALID, no revert)…");
  const built = await anyClient.buildUserOperation({ uo: callData });
  latestUo = asPacked(built);
  console.log("nonce", latestUo.nonce.toString());
  console.log("estimate verificationGasLimit", built.verificationGasLimit);
  console.log("estimate callGasLimit", built.callGasLimit);

  // Dummy-path underestimate: EIP-1271 + large Proof needs more verification gas.
  // Pick VGL in a band that avoids AA26 while keeping Alchemy efficiency ≥ 0.4.
  const estimatedVgl = BigInt(built.verificationGasLimit as string);
  // Real EIP-1271 Proof embeds full callData; dummy INVALID exits early so
  // estimates are far too low. 500k is a PoC floor that still fits Alchemy's
  // used/limit ≥ 0.4 band once validation actually runs.
  const bumpedVgl = estimatedVgl < 500_000n ? 500_000n : estimatedVgl;
  console.log("using verificationGasLimit", bumpedVgl.toString());

  latestUo = {
    ...latestUo,
    accountGasLimits: packUints(
      bumpedVgl,
      BigInt(built.callGasLimit as string),
    ),
  };

  const rpc = async (method: string, params: unknown[]) => {
    const res = await fetch(`https://base-mainnet.g.alchemy.com/v2/${apiKey}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    });
    const json = (await res.json()) as {
      result?: unknown;
      error?: { message?: string; data?: unknown };
    };
    if (json.error) {
      throw new Error(
        `${method}: ${json.error.message} ${JSON.stringify(json.error.data ?? "")}`,
      );
    }
    return json.result;
  };

  // Refresh paymaster to match bumped VGL + live signature.
  let signature = await packContractOwnerSig({
    account: automation,
    policySigner,
    chainId: base.id,
    validUntil,
    uo: latestUo,
  });

  const gasResult = (await rpc("alchemy_requestGasAndPaymasterAndData", [
    {
      policyId,
      entryPoint: ENTRY_POINT,
      userOperation: {
        sender: latestUo.sender,
        nonce: `0x${latestUo.nonce.toString(16)}`,
        callData: latestUo.callData,
        signature,
      },
      dummySignature: signature,
      overrides: {
        verificationGasLimit: `0x${bumpedVgl.toString(16)}`,
        callGasLimit: built.callGasLimit,
        preVerificationGas:
          typeof built.preVerificationGas === "bigint"
            ? `0x${built.preVerificationGas.toString(16)}`
            : built.preVerificationGas,
        maxFeePerGas: built.maxFeePerGas,
        maxPriorityFeePerGas: built.maxPriorityFeePerGas,
      },
    },
  ])) as Record<string, unknown>;

  // Keep our bumped VGL; take refreshed paymaster + fees.
  const pm = getAddress(gasResult.paymaster as string);
  const pmVerif = BigInt(gasResult.paymasterVerificationGasLimit as string);
  const pmPost = BigInt(gasResult.paymasterPostOpGasLimit as string);
  const pmData = (gasResult.paymasterData as Hex | undefined) ?? ("0x" as Hex);
  latestUo = {
    ...latestUo,
    preVerificationGas: BigInt(gasResult.preVerificationGas as string),
    gasFees: packUints(
      BigInt(gasResult.maxPriorityFeePerGas as string),
      BigInt(gasResult.maxFeePerGas as string),
    ),
    paymasterAndData: concatHex([
      pm,
      (`0x${pmVerif.toString(16).padStart(32, "0")}`) as Hex,
      (`0x${pmPost.toString(16).padStart(32, "0")}`) as Hex,
      pmData,
    ]),
  };

  signature = await packContractOwnerSig({
    account: automation,
    policySigner,
    chainId: base.id,
    validUntil,
    uo: latestUo,
  });

  const userOpV07 = {
    sender: latestUo.sender,
    nonce: `0x${latestUo.nonce.toString(16)}` as Hex,
    callData: latestUo.callData,
    callGasLimit: (gasResult.callGasLimit as Hex) ?? (built.callGasLimit as Hex),
    verificationGasLimit: `0x${bumpedVgl.toString(16)}` as Hex,
    preVerificationGas: `0x${latestUo.preVerificationGas.toString(16)}` as Hex,
    maxFeePerGas: gasResult.maxFeePerGas as Hex,
    maxPriorityFeePerGas: gasResult.maxPriorityFeePerGas as Hex,
    paymaster: pm,
    paymasterData: pmData,
    paymasterVerificationGasLimit: gasResult.paymasterVerificationGasLimit as Hex,
    paymasterPostOpGasLimit: gasResult.paymasterPostOpGasLimit as Hex,
    signature,
  };

  console.log("Sending eth_sendUserOperation…");
  const hash = (await rpc("eth_sendUserOperation", [
    userOpV07,
    ENTRY_POINT,
  ])) as Hex;
  console.log("UserOp hash", hash);

  let txHash: Hex | undefined;
  for (let i = 0; i < 40; i++) {
    const receipt = (await rpc("eth_getUserOperationReceipt", [hash])) as
      | { receipt?: { transactionHash?: Hex }; transactionHash?: Hex }
      | null;
    if (receipt) {
      txHash =
        receipt.receipt?.transactionHash ??
        receipt.transactionHash ??
        undefined;
      if (txHash) break;
    }
    await new Promise((r) => setTimeout(r, 1500));
  }
  if (!txHash) throw new Error("Timed out waiting for UserOp receipt");
  console.log("tx", txHash);

  const after = await readBal();
  const allowance = await publicClient.readContract({
    address: asset,
    abi: erc20Abi,
    functionName: "allowance",
    args: [accountAddr, executor],
  });
  console.log("balances after", {
    ...after,
    usdcAllowanceToExecutor: allowance.toString(),
  });
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
