/**
 * Owner onboarding for GrowYield EIP-1271 PoC on Alchemy MA v2.
 *
 * One owner UserOp:
 *   executeBatch([
 *     policySigner.configure(automationSigner, validUntil),
 *     this.installValidation(SingleSigner → policySigner, entityId, executeBatch only)
 *   ])
 *
 * Env: ALCHEMY_API_KEY, ALCHEMY_GAS_POLICY_ID, OWNER_PRIVATE_KEY,
 *      POLICY_SIGNER, ACCOUNT (optional), ENTITY_ID (default 2 — avoid V6 entity 1)
 *
 * Run from grow-backend:
 *   NODE_PATH=./node_modules npx tsx ../grow-allocation-controller/script/ts/mav2-poc/run-1271-onboard.ts
 */

import {
  encodeFunctionData,
  encodeAbiParameters,
  encodePacked,
  getAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createModularAccountV2Client } from "@account-kit/smart-contracts";
import { installValidationActions } from "@account-kit/smart-contracts/experimental";
import { alchemy, base as akBase } from "@account-kit/infra";
import { LocalAccountSigner } from "@aa-sdk/core";
import { config as dotenvConfig } from "dotenv";
import { resolve } from "path";

dotenvConfig({ path: resolve(__dirname, "../../../../grow-backend/.env") });
dotenvConfig({ path: "/tmp/grow_v6_poc.env" });
dotenvConfig({ path: "/tmp/grow_1271_poc.env" });

const EXECUTE_BATCH_SELECTOR = "0x34fcd5be" as Hex;
const SINGLE_SIGNER_VALIDATION =
  "0x00000000000099DE0BF6fA90dEB851E2A2df7d83" as Address;

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

const INSTALL_VALIDATION_ABI = [
  {
    type: "function",
    name: "installValidation",
    stateMutability: "nonpayable",
    inputs: [
      { name: "validationConfig", type: "bytes25" },
      { name: "selectors", type: "bytes4[]" },
      { name: "installData", type: "bytes" },
      { name: "hooks", type: "bytes[]" },
    ],
    outputs: [],
  },
] as const;

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env ${name}`);
  return v;
}

function packValidationConfig(params: {
  moduleAddress: Address;
  entityId: number;
  isGlobal: boolean;
  isSignatureValidation: boolean;
  isUserOpValidation: boolean;
}): Hex {
  const flags =
    (params.isUserOpValidation ? 1 : 0) +
    (params.isSignatureValidation ? 2 : 0) +
    (params.isGlobal ? 4 : 0);
  return encodePacked(
    ["address", "uint32", "uint8"],
    [params.moduleAddress, params.entityId, flags],
  );
}

async function main() {
  const apiKey = requireEnv("ALCHEMY_API_KEY");
  const ownerPk = requireEnv("OWNER_PRIVATE_KEY") as Hex;
  const automationPk = (process.env.AUTOMATION_PRIVATE_KEY ||
    process.env.SESSION_KEY_PRIVATE_KEY) as Hex;
  if (!automationPk) throw new Error("Missing AUTOMATION_PRIVATE_KEY");

  const policySigner = getAddress(requireEnv("POLICY_SIGNER"));
  const policyId =
    process.env.ALCHEMY_GAS_POLICY_ID ||
    process.env.ALCHEMY_GAS_MANAGER_POLICY_ID;
  if (!policyId) throw new Error("Missing ALCHEMY_GAS_POLICY_ID");

  const entityId = Number(process.env.ENTITY_ID || 2);
  const configValidUntil = Number(process.env.CONFIG_VALID_UNTIL || 0);

  const owner = privateKeyToAccount(ownerPk);
  const automation = privateKeyToAccount(automationPk);

  console.log("Owner", owner.address);
  console.log("Automation", automation.address);
  console.log("Policy signer", policySigner);
  console.log("EntityId", entityId);

  const ownerClient = (
    await createModularAccountV2Client({
      chain: akBase,
      transport: alchemy({ apiKey }),
      signer: LocalAccountSigner.privateKeyToAccountSigner(ownerPk),
      accountAddress: process.env.ACCOUNT as Address | undefined,
      policyId,
    })
  ).extend(installValidationActions);

  const account = ownerClient.account.address as Address;
  console.log("Smart account", account);

  const configureData = encodeFunctionData({
    abi: [
      {
        type: "function",
        name: "configure",
        stateMutability: "nonpayable",
        inputs: [
          { name: "signer", type: "address" },
          { name: "validUntil", type: "uint48" },
        ],
        outputs: [],
      },
    ],
    functionName: "configure",
    args: [automation.address, configValidUntil],
  });

  const validationConfig = packValidationConfig({
    moduleAddress: SINGLE_SIGNER_VALIDATION,
    entityId,
    isGlobal: false,
    isSignatureValidation: false,
    isUserOpValidation: true,
  });

  const installData = encodeAbiParameters(
    [{ type: "uint32" }, { type: "address" }],
    [entityId, policySigner],
  );

  const installValidationData = encodeFunctionData({
    abi: INSTALL_VALIDATION_ABI,
    functionName: "installValidation",
    args: [validationConfig, [EXECUTE_BATCH_SELECTOR], installData, []],
  });

  const callData = encodeFunctionData({
    abi: EXECUTE_BATCH_ABI,
    functionName: "executeBatch",
    args: [
      [
        { target: policySigner, value: 0n, data: configureData },
        { target: account, value: 0n, data: installValidationData },
      ],
    ],
  });

  console.log("Sending one-time owner onboarding UserOp…");
  const { hash } = await ownerClient.sendUserOperation({ uo: callData });
  console.log("UserOp hash", hash);
  const tx = await ownerClient.waitForUserOperationTransaction({ hash });
  console.log("Onboarding tx", tx);
  console.log("Success: configured automation + installed SingleSigner→1271");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
