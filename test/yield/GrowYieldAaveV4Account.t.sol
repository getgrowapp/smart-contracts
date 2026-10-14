// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IEntryPoint} from "@eth-infinitism/account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {
    Call, IModularAccount
} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {ValidationConfigLib} from
    "@erc6900/reference-implementation/libraries/ValidationConfigLib.sol";
import {DIRECT_CALL_VALIDATION_ENTITY_ID} from
    "@erc6900/reference-implementation/helpers/Constants.sol";
import {EntryPointUtils} from "../../lib/reference-implementation/test/utils/EntryPointUtils.sol";
import {ModularAccount} from "@alchemy/modular-account/account/ModularAccount.sol";
import {ExecutionLib} from "@alchemy/modular-account/libraries/ExecutionLib.sol";
import {ExecutionInstallDelegate} from
    "@alchemy/modular-account/helpers/ExecutionInstallDelegate.sol";
import {IGrowYieldAccountCall} from "../../src/interfaces/IGrowYieldAccountCall.sol";

import {MockUnderlying} from "../invariant/MockYieldVenues.sol";
import {AaveV4SpokeAdapter} from "../../src/adapters/AaveV4SpokeAdapter.sol";
import {GrowYieldExecutor} from "../../src/GrowYieldExecutor.sol";
import {GrowYieldPlugin} from "../../src/GrowYieldPlugin.sol";
import {IAaveV4Hub} from "../../src/interfaces/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/IAaveV4Spoke.sol";
import {
    IGrowYieldExecutor,
    AmountMode,
    Operation,
    OperationKind
} from "../../src/interfaces/IGrowYieldExecutor.sol";
import {
    IGrowYieldAdapterRegistry, Protocol
} from "../../src/interfaces/IGrowYieldAdapterRegistry.sol";
import {AlchemySingleSignerValidationModuleHarness} from
    "./mocks/AlchemySingleSignerValidationModuleHarness.sol";
import {MockSponsorPaymaster} from "./mocks/MockSponsorPaymaster.sol";

interface IHubAsset {
    function getAsset(uint256 assetId)
        external
        view
        returns (
            uint120 liquidity,
            uint120 realizedFees,
            uint8 decimals,
            uint120 addedShares,
            uint120 swept,
            int200 premiumOffsetRay,
            uint120 drawnShares,
            uint120 premiumShares,
            uint16 liquidityFee,
            uint120 drawnIndex,
            uint96 drawnRate,
            uint40 lastUpdateTimestamp,
            address underlying,
            address irStrategy,
            address reinvestmentController,
            address feeReceiver,
            uint200 deficitRay
        );
}

/// @notice An EOA owns a Modular Account v2 and moves 0.0001 AAPLc through the Coinbase spoke.
/// @dev The token is minted on a Base fork. Nothing is broadcast.
contract GrowYieldAaveV4AccountTest is EntryPointUtils {
    using MessageHashUtils for bytes32;

    address internal constant HUB = 0xa4d5947Eb727A052bae69C593FfC84247EC9864E;
    address internal constant SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;
    address internal constant AAPL = 0xb200000000000000000000C2e324d24d7eEcd1fb;
    /// @dev 0.0001 AAPLc. Eight decimals, so this is 10_000 base units.
    uint256 internal constant SMALL_AMOUNT = 10_000;

    uint32 internal constant OWNER_ENTITY_ID = 0;
    uint32 internal constant POLICY_ENTITY_ID = 1;
    uint8 internal constant FINAL_SEGMENT_INDEX = 0xFF;

    IEntryPoint internal entryPoint;
    GrowYieldExecutor internal executor;
    GrowYieldPlugin internal plugin;
    AaveV4SpokeAdapter internal adapter;
    MockSponsorPaymaster internal paymaster;
    address internal venue;
    address internal account;

    address internal owner;
    uint256 internal ownerKey;
    address internal automation;
    uint256 internal automationPk;
    address payable internal beneficiary;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        (owner, ownerKey) = makeAddrAndKey("owner");
        (automation, automationPk) = makeAddrAndKey("automation");
        beneficiary = payable(makeAddr("beneficiary"));
        entryPoint = _deployEntryPoint();

        AlchemySingleSignerValidationModuleHarness ownerModule =
            new AlchemySingleSignerValidationModuleHarness();
        ExecutionInstallDelegate executionInstallDelegate = new ExecutionInstallDelegate();
        account = address(
            new ERC1967Proxy(
                address(new ModularAccount(entryPoint, executionInstallDelegate)),
                abi.encodeCall(
                    ModularAccount.initializeWithValidation,
                    (
                        ValidationConfigLib.pack(
                            address(ownerModule), OWNER_ENTITY_ID, true, true, true
                        ),
                        new bytes4[](0),
                        abi.encode(OWNER_ENTITY_ID, owner),
                        new bytes[](0)
                    )
                )
            )
        );

        paymaster = new MockSponsorPaymaster(entryPoint);
        vm.deal(address(this), 1 ether);
        paymaster.deposit{value: 0.05 ether}();

        executor = new GrowYieldExecutor(
            50,
            makeAddr("riskGuardian"),
            address(this),
            IGrowYieldAdapterRegistry.Registrars({
                aavePool: address(0),
                aaveDataProvider: address(0),
                morphoVaultFactory: address(0),
                morphoAdapterFactory: address(0),
                morphoEligibility: address(0),
                eulerEVaultFactory: address(0),
                eulerEarnFactory: address(0),
                capyFiComptroller: address(0),
                aaveV4Hub: HUB
            })
        );
        plugin = new GrowYieldPlugin(500_000, 2_000_000, 150_000, 200_000, 200_000, 2 gwei, 2 gwei);
        adapter = new AaveV4SpokeAdapter(IAaveV4Hub(HUB), address(executor));
        venue = executor.deployAaveV4ReserveVenue(SPOKE, 0);

        IGrowYieldAdapterRegistry.VaultConfig[] memory vaults =
            new IGrowYieldAdapterRegistry.VaultConfig[](1);
        vaults[0] = IGrowYieldAdapterRegistry.VaultConfig({
            adapter: address(adapter),
            vault: venue,
            protocol: Protocol.AAVE_V4,
            canDeposit: true,
            canRedeem: true
        });
        executor.addVaults(vaults);
        _mintSmallAapl(account);
    }

    /// @dev 0.0001 AAPLc moves onto the spoke and back. Collateral turns on with the deposit and
    ///      off when the supply is gone. The account does not borrow.
    function test_fork_eoaAccountDepositsAndWithdrawsSmallAapl() public {
        _installPolicy();
        _depositAndWithdraw();
    }

    /// @dev The production install is one owner userOp. Its calldata is `executeBatch` of the
    ///      policy validation, the direct-call validation, and the spoke execution manifest.
    function test_fork_oneOwnerUserOpInstallsSpokeAndRoundTrips() public {
        uint256 nonceBefore = entryPoint.getNonce(account, 1);
        _installPolicyInOneUserOp();
        assertEq(entryPoint.getNonce(account, 1), nonceBefore + 1);
        _depositAndWithdraw();
    }

    function _depositAndWithdraw() internal {
        assertEq(IERC20(AAPL).balanceOf(account), SMALL_AMOUNT);

        vm.prank(makeAddr("stranger"));
        vm.expectPartialRevert(ExecutionLib.PreExecHookReverted.selector);
        IGrowYieldAccountCall(account).supplyOnSpoke(SPOKE, 0, SMALL_AMOUNT);

        _runPolicyUserOp(_executorCall(_depositOps()));

        assertEq(IERC20(AAPL).balanceOf(account), 0);
        assertGt(adapter.suppliedShares(venue, account), 0);
        assertEq(IERC20(AAPL).allowance(account, SPOKE), 0);
        (bool collateral, bool borrowing) = IAaveV4Spoke(SPOKE).getUserReserveStatus(0, account);
        assertTrue(collateral);
        assertFalse(borrowing);

        _runPolicyUserOp(_executorCall(_redeemOps()));

        assertEq(adapter.suppliedShares(venue, account), 0);
        assertGe(IERC20(AAPL).balanceOf(account), SMALL_AMOUNT - 1);
        (collateral, borrowing) = IAaveV4Spoke(SPOKE).getUserReserveStatus(0, account);
        assertFalse(collateral);
        assertFalse(borrowing);
    }

    function _depositOps() internal view returns (Operation[] memory ops) {
        ops = new Operation[](1);
        ops[0] = Operation({
            vault: venue,
            kind: OperationKind.DEPOSIT,
            sourceToken: AAPL,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
    }

    function _redeemOps() internal view returns (Operation[] memory ops) {
        ops = new Operation[](1);
        ops[0] = Operation({
            vault: venue,
            kind: OperationKind.REDEEM,
            sourceToken: venue,
            amount: 0,
            amountMode: AmountMode.FULL_BALANCE,
            minAmountOut: 1
        });
    }

    function _executorCall(Operation[] memory ops) internal view returns (bytes memory) {
        return abi.encodeCall(
            IModularAccount.execute,
            (address(executor), 0, abi.encodeCall(IGrowYieldExecutor.execute, (ops)))
        );
    }

    function _installPolicy() internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IModularAccount.execute.selector;
        address[] memory initialOwners = new address[](1);
        initialOwners[0] = automation;

        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.installValidation,
                (
                    ValidationConfigLib.pack(address(plugin), POLICY_ENTITY_ID, false, false, true),
                    selectors,
                    abi.encode(
                        POLICY_ENTITY_ID, initialOwners, address(executor), address(paymaster)
                    ),
                    new bytes[](0)
                )
            )
        );
        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.installValidation,
                (
                    ValidationConfigLib.pack(
                        address(plugin), DIRECT_CALL_VALIDATION_ENTITY_ID, false, false, false
                    ),
                    selectors,
                    "",
                    new bytes[](0)
                )
            )
        );
        _runOwnerUserOp(
            abi.encodeCall(
                IModularAccount.installExecution, (address(plugin), plugin.executionManifest(), "")
            )
        );
    }

    /// @dev One owner signature. The account calls itself three times, which is the shape the
    ///      install userOp should send.
    function _installPolicyInOneUserOp() internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IModularAccount.execute.selector;
        address[] memory initialOwners = new address[](1);
        initialOwners[0] = automation;

        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            target: account,
            value: 0,
            data: abi.encodeCall(
                IModularAccount.installValidation,
                (
                    ValidationConfigLib.pack(address(plugin), POLICY_ENTITY_ID, false, false, true),
                    selectors,
                    abi.encode(POLICY_ENTITY_ID, initialOwners, address(executor), address(paymaster)),
                    new bytes[](0)
                )
            )
        });
        calls[1] = Call({
            target: account,
            value: 0,
            data: abi.encodeCall(
                IModularAccount.installValidation,
                (
                    ValidationConfigLib.pack(
                        address(plugin), DIRECT_CALL_VALIDATION_ENTITY_ID, false, false, false
                    ),
                    selectors,
                    "",
                    new bytes[](0)
                )
            )
        });
        calls[2] = Call({
            target: account,
            value: 0,
            data: abi.encodeCall(
                IModularAccount.installExecution, (address(plugin), plugin.executionManifest(), "")
            )
        });
        _runOwnerUserOp(abi.encodeCall(IModularAccount.executeBatch, (calls)));
    }

    function _runOwnerUserOp(bytes memory callData) internal {
        PackedUserOperation memory userOp = _userOp(callData, 1);
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(ownerKey, entryPoint.getUserOpHash(userOp).toEthSignedMessageHash());
        userOp.signature = abi.encodePacked(FINAL_SEGMENT_INDEX, bytes1(uint8(0)), r, s, v);
        _handleOps(userOp);
    }

    function _runPolicyUserOp(bytes memory callData) internal {
        PackedUserOperation memory userOp = _userOp(callData, uint192(POLICY_ENTITY_ID) << 8);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                keccak256(
                    abi.encode(
                        keccak256(
                            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                        ),
                        keccak256(bytes("GrowYieldPolicy")),
                        keccak256(bytes("1")),
                        block.chainid,
                        address(plugin)
                    )
                ),
                keccak256(
                    abi.encode(
                        keccak256("GrowYieldAuthorization(bytes32 userOpHash)"),
                        entryPoint.getUserOpHash(userOp)
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(automationPk, digest);
        userOp.signature = abi.encodePacked(FINAL_SEGMENT_INDEX, r, s, v);
        _handleOps(userOp);
    }

    function _userOp(bytes memory callData, uint192 nonceKey)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp.sender = account;
        userOp.nonce = entryPoint.getNonce(account, nonceKey);
        userOp.callData = callData;
        userOp.accountGasLimits = bytes32((uint256(500_000) << 128) | uint256(2_000_000));
        userOp.preVerificationGas = 100_000;
        userOp.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(1 gwei));
        userOp.paymasterAndData =
            abi.encodePacked(address(paymaster), uint128(100_000), uint128(100_000));
    }

    function _handleOps(PackedUserOperation memory userOp) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        entryPoint.handleOps(ops, beneficiary);
    }

    /// @dev B20 cannot execute under Foundry. Etch an ERC-20 and seed the hub's existing liquidity
    ///      so `Hub.add` accepts the transfer. The account receives only `SMALL_AMOUNT`.
    function _mintSmallAapl(address to) internal {
        (uint120 liquidity,,,,,,,,,,,,,,,,) = IHubAsset(HUB).getAsset(0);
        MockUnderlying impl = new MockUnderlying();
        vm.etch(AAPL, address(impl).code);
        MockUnderlying(AAPL).mint(HUB, uint256(liquidity) + SMALL_AMOUNT);
        MockUnderlying(AAPL).mint(to, SMALL_AMOUNT);
    }
}
