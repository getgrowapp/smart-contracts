// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PackedUserOperation} from
    "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {_packValidationData} from "@eth-infinitism/account-abstraction/core/Helpers.sol";
import {UserOperationLib} from "@eth-infinitism/account-abstraction/core/UserOperationLib.sol";
import {IValidationModule} from "@erc6900/reference-implementation/interfaces/IValidationModule.sol";
import {IModule} from "@erc6900/reference-implementation/interfaces/IModule.sol";
import {IExecutionHookModule} from
    "@erc6900/reference-implementation/interfaces/IExecutionHookModule.sol";
import {
    ExecutionManifest,
    IExecutionModule,
    ManifestExecutionFunction as Erc6900ExecutionFunction,
    ManifestExecutionHook as Erc6900ExecutionHook
} from "@erc6900/reference-implementation/interfaces/IExecutionModule.sol";
import {IModularAccount} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {UserOperation} from "@alchemy/msca/interfaces/erc4337/UserOperation.sol";
import {
    ManifestFunction,
    ManifestAssociatedFunctionType,
    ManifestAssociatedFunction,
    ManifestExecutionHook,
    PluginManifest,
    PluginMetadata,
    IPlugin
} from "@alchemy/msca/interfaces/IPlugin.sol";
import {IPluginExecutor} from "@alchemy/msca/interfaces/IPluginExecutor.sol";
import {IStandardExecutor} from "@alchemy/msca/interfaces/IStandardExecutor.sol";
import {SIG_VALIDATION_PASSED, SIG_VALIDATION_FAILED} from "@alchemy/msca/libraries/Constants.sol";
import {BasePlugin} from "@alchemy/msca/plugins/BasePlugin.sol";

import {AaveV4ReserveVenue} from "./AaveV4ReserveVenue.sol";
import {IAaveV4Spoke} from "./interfaces/IAaveV4Spoke.sol";
import {IAaveV4SpokeAdapter} from "./interfaces/IAaveV4SpokeAdapter.sol";
import {IGrowYieldAccountCall} from "./interfaces/IGrowYieldAccountCall.sol";
import {IGrowYieldExecutor, Operation} from "./interfaces/IGrowYieldExecutor.sol";
import {Protocol, Venue} from "./interfaces/IGrowYieldAdapterRegistry.sol";
import {IGrowYieldPolicyModule} from "./interfaces/IGrowYieldPolicyModule.sol";
import {GrowYieldPluginEphemeralLib} from "./GrowYieldPluginEphemeralLib.sol";
import {GrowYieldPolicyLib} from "./GrowYieldPolicyLib.sol";

/// @title GrowYieldPlugin
/// @notice MSCA plugin and ERC-6900 validation module for policy-owner-authorized yield operations.
/// @custom:security-contact security@getgrowapp.co
contract GrowYieldPlugin is
    IGrowYieldPolicyModule,
    IGrowYieldAccountCall,
    IExecutionModule,
    IExecutionHookModule,
    BasePlugin,
    EIP712
{
    using UserOperationLib for PackedUserOperation;

    uint256 private constant SIGNATURE_LENGTH = 65;
    uint256 private constant PAYMASTER_ADDRESS_LENGTH = 20;
    /// @dev Where EntryPoint v0.7 paymaster data begins, i.e. past the two packed gas limits.
    uint256 private constant PAYMASTER_DATA_OFFSET = 52;
    uint256 private constant MAX_PAYMASTER_AND_DATA_LENGTH = 512;

    bytes4 private constant ERC1271_INVALID = 0xffffffff;
    bytes32 private constant AUTHORIZATION_TYPEHASH =
        keccak256("GrowYieldAuthorization(bytes32 userOpHash)");

    uint8 public constant MAX_OWNERS = 8;

    /// @notice Routes validation for the spoke calls the executor asks the account to make.
    uint8 public constant SPOKE_CALL_FUNCTION_ID = 1;

    /// @notice Entity id of the ERC-6900 pre-exec hook on the three spoke selectors.
    uint32 public constant SPOKE_HOOK_ENTITY_ID = 1;

    error SpokeApprovalFailed();
    /// @notice The spoke and reserve are not an Aave V4 venue this account's executor has admitted.
    error SpokeNotAdmitted();

    /// @dev Set by the pre-execution hook when the caller is the account's executor, then consumed
    ///      by the spoke call. `executeFromPlugin` skips runtime validation, and a direct call to
    ///      this plugin skips both. Neither leaves this set.
    address private transient _spokeCaller;

    uint128 public immutable maxVerificationGas;
    uint128 public immutable maxCallGas;
    uint256 public immutable maxPreVerificationGas;
    uint128 public immutable maxPaymasterVerificationGas;
    uint128 public immutable maxPaymasterPostOpGas;
    uint128 public immutable maxPriorityFeePerGas;
    uint128 public immutable maxFeePerGas;

    struct AccountConfig {
        uint32 entityId;
        uint8 ownerCount;
        address executor;
        address paymaster;
        address[MAX_OWNERS] owners;
    }

    mapping(address account => AccountConfig) private _accountConfigs;

    constructor(
        uint128 maxVerificationGas_,
        uint128 maxCallGas_,
        uint256 maxPreVerificationGas_,
        uint128 maxPaymasterVerificationGas_,
        uint128 maxPaymasterPostOpGas_,
        uint128 maxPriorityFeePerGas_,
        uint128 maxFeePerGas_
    ) EIP712("GrowYieldPolicy", "1") {
        if (
            maxVerificationGas_ == 0 || maxCallGas_ == 0 || maxPreVerificationGas_ == 0
                || maxPaymasterVerificationGas_ == 0 || maxPaymasterPostOpGas_ == 0
                || maxFeePerGas_ == 0 || maxPriorityFeePerGas_ > maxFeePerGas_
        ) revert InvalidConfiguration();

        maxVerificationGas = maxVerificationGas_;
        maxCallGas = maxCallGas_;
        maxPreVerificationGas = maxPreVerificationGas_;
        maxPaymasterVerificationGas = maxPaymasterVerificationGas_;
        maxPaymasterPostOpGas = maxPaymasterPostOpGas_;
        maxPriorityFeePerGas = maxPriorityFeePerGas_;
        maxFeePerGas = maxFeePerGas_;
    }

    function executeGrowYield(address executor, bytes calldata executorCallData)
        external
        returns (bytes memory)
    {
        _requireApprovedExecutor(executor);
        return IPluginExecutor(msg.sender).executeFromPluginExternal(executor, 0, executorCallData);
    }

    /// @notice Approve the executor per unique `sourceToken`, run `executor.execute(ops)`, then revoke.
    function executeGrowYieldWithEphemeralAllowance(address executor, Operation[] calldata ops)
        external
        returns (bytes memory)
    {
        _requireApprovedExecutor(executor);
        return GrowYieldPluginEphemeralLib.executeWithEphemeralAllowance(executor, ops);
    }

    /// @inheritdoc IGrowYieldAccountCall
    /// @dev `msg.sender` is the account. The account calls the spoke, so Aave sees the account.
    ///      The approved token is the asset pinned at admission.
    function supplyOnSpoke(address spoke, uint256 reserveId, uint256 amount) external {
        address account = msg.sender;
        Venue memory admitted = _admittedSpoke(spoke, reserveId, true);
        _approveFromAccount(account, admitted.asset, spoke, amount);
        _callFromAccount(
            account, spoke, abi.encodeCall(IAaveV4Spoke.supply, (reserveId, amount, account))
        );
        _approveFromAccount(account, admitted.asset, spoke, 0);
    }

    /// @inheritdoc IGrowYieldAccountCall
    function withdrawOnSpoke(address spoke, uint256 reserveId, uint256 amount) external {
        address account = msg.sender;
        _admittedSpoke(spoke, reserveId, false);
        _callFromAccount(
            account, spoke, abi.encodeCall(IAaveV4Spoke.withdraw, (reserveId, amount, account))
        );
    }

    /// @inheritdoc IGrowYieldAccountCall
    function setSpokeCollateral(address spoke, uint256 reserveId, bool usingAsCollateral)
        external
    {
        address account = msg.sender;
        _admittedSpoke(spoke, reserveId, usingAsCollateral);
        _callFromAccount(
            account,
            spoke,
            abi.encodeCall(
                IAaveV4Spoke.setUsingAsCollateral, (reserveId, usingAsCollateral, account)
            )
        );
    }

    /// @inheritdoc BasePlugin
    function runtimeValidationFunction(uint8 functionId, address sender, uint256, bytes calldata)
        external
        view
        override
    {
        if (functionId != SPOKE_CALL_FUNCTION_ID) revert NotImplemented(msg.sig, functionId);
        _requireSpokeCaller(sender);
    }

    /// @inheritdoc BasePlugin
    /// @dev Runs for a direct call and for `executeFromPlugin`. Runtime validation does not run
    ///      on the latter, so this is the check that rejects every caller except the executor.
    function preExecutionHook(uint8 functionId, address sender, uint256, bytes calldata)
        external
        override
        returns (bytes memory)
    {
        if (functionId != SPOKE_CALL_FUNCTION_ID) revert NotImplemented(msg.sig, functionId);
        _requireSpokeCaller(sender);
        _spokeCaller = msg.sender;
        return "";
    }

    /// @dev Modular Account v2 calls this overload. `sender` is the original caller. The account
    ///      is `msg.sender`. The executor is not a validation module, so the selectors are
    ///      installed as public and this hook is what rejects every other caller.
    function preExecutionHook(uint32 entityId, address sender, uint256, bytes calldata)
        external
        override
        returns (bytes memory)
    {
        if (entityId != SPOKE_HOOK_ENTITY_ID) revert InvalidConfiguration();
        _requireSpokeCaller(sender);
        _spokeCaller = msg.sender;
        return "";
    }

    /// @dev The spoke manifest installs no post hook. A post hook would run after the spoke call
    ///      and could not undo it, so one is refused.
    function postExecutionHook(uint32, bytes calldata) external pure override {
        revert InvalidConfiguration();
    }

    function addOwner(address owner) external {
        if (_accountConfigs[msg.sender].entityId == 0) revert PolicyNotInstalled();
        _addOwner(msg.sender, owner);
    }

    function removeOwner(address owner) external {
        AccountConfig storage accountConfig = _accountConfigs[msg.sender];
        if (accountConfig.entityId == 0) revert PolicyNotInstalled();
        uint8 count = accountConfig.ownerCount;

        for (uint256 i; i < count; ++i) {
            if (accountConfig.owners[i] != owner) continue;

            uint8 last = count - 1;
            if (i != last) accountConfig.owners[i] = accountConfig.owners[last];
            delete accountConfig.owners[last];
            accountConfig.ownerCount = last;
            emit OwnerRemoved(msg.sender, owner);
            return;
        }

        revert OwnerNotFound();
    }

    function isOwner(address account, address owner) public view returns (bool) {
        AccountConfig storage accountConfig = _accountConfigs[account];
        uint8 count = accountConfig.ownerCount;
        for (uint256 i; i < count; ++i) {
            if (accountConfig.owners[i] == owner) return true;
        }
        return false;
    }

    function ownerCount(address account) external view returns (uint8) {
        return _accountConfigs[account].ownerCount;
    }

    function ownerAt(address account, uint256 index) external view returns (address) {
        if (index >= _accountConfigs[account].ownerCount) revert OwnerNotFound();
        return _accountConfigs[account].owners[index];
    }

    function policyEntityId(address account) external view returns (uint32) {
        return _accountConfigs[account].entityId;
    }

    function setExecutor(address executor) external {
        AccountConfig storage accountConfig = _accountConfigs[msg.sender];
        if (accountConfig.entityId == 0) revert PolicyNotInstalled();
        _setExecutor(msg.sender, executor);
    }

    function accountExecutor(address account) external view returns (address) {
        return _accountConfigs[account].executor;
    }

    function setPaymaster(address paymaster) external {
        if (_accountConfigs[msg.sender].entityId == 0) revert PolicyNotInstalled();
        _setPaymaster(msg.sender, paymaster);
    }

    function accountPaymaster(address account) external view returns (address) {
        return _accountConfigs[account].paymaster;
    }

    function validateUserOp(
        uint32 entityId,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external view override returns (uint256) {
        bool valid = entityId != 0 && entityId == _accountConfigs[userOp.sender].entityId
            && msg.sender == userOp.sender && userOp.signature.length == SIGNATURE_LENGTH;

        if (valid) {
            valid = userOp.initCode.length == 0 && _gasPolicyAllows(userOp)
                && _paymasterPolicyAllows(userOp.sender, userOp.paymasterAndData);
        }

        if (valid) {
            try this.isAllowedCallData(userOp.sender, userOp.callData) returns (bool allowed) {
                valid = allowed;
            } catch {
                valid = false;
            }
        }

        if (valid) {
            bytes32 digest =
                _hashTypedDataV4(keccak256(abi.encode(AUTHORIZATION_TYPEHASH, userOpHash)));
            (address recovered, ECDSA.RecoverError recoverError,) =
                ECDSA.tryRecoverCalldata(digest, userOp.signature);
            valid = recoverError == ECDSA.RecoverError.NoError && isOwner(userOp.sender, recovered);
        }

        return _packValidationData(!valid, 0, 0);
    }

    function authorizationDigest(bytes32 userOpHash) external view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(AUTHORIZATION_TYPEHASH, userOpHash)));
    }

    function isAllowedCallData(address account, bytes calldata callData)
        external
        view
        returns (bool)
    {
        address accountExecutor_ = _accountConfigs[account].executor;
        return accountExecutor_ != address(0)
            && GrowYieldPolicyLib.isAllowed(accountExecutor_, callData);
    }

    function validateRuntime(address, uint32, address, uint256, bytes calldata, bytes calldata)
        external
        pure
        override
    {
        revert NotImplemented(msg.sig, 0);
    }

    function validateSignature(address, uint32, address, bytes32, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return ERC1271_INVALID;
    }

    function onInstall(bytes calldata data) external override(BasePlugin, IModule) {
        if (_accountConfigs[msg.sender].entityId != 0) revert PolicyAlreadyInstalled();

        (uint32 entityId, address[] memory initialOwners, address executor, address paymaster) =
            abi.decode(data, (uint32, address[], address, address));
        if (entityId == 0 || initialOwners.length == 0 || initialOwners.length > MAX_OWNERS) {
            revert InvalidConfiguration();
        }

        _accountConfigs[msg.sender].entityId = entityId;
        for (uint256 i; i < initialOwners.length; ++i) {
            _addOwner(msg.sender, initialOwners[i]);
        }
        _setExecutor(msg.sender, executor);
        _setPaymaster(msg.sender, paymaster);
    }

    function onUninstall(bytes calldata) external override(BasePlugin, IModule) {
        _clearAccountConfig(msg.sender);
    }

    function moduleId() external pure returns (string memory) {
        return "grow.yield-policy.7.0.0";
    }

    function userOpValidationFunction(
        uint8 functionId,
        UserOperation calldata userOp,
        bytes32 userOpHash
    ) external view override returns (uint256) {
        if (functionId != 0) revert NotImplemented(msg.sig, functionId);

        address account = msg.sender;
        if (
            _accountConfigs[account].entityId == 0 || userOp.signature.length != SIGNATURE_LENGTH
                || userOp.initCode.length != 0 || userOp.verificationGasLimit > maxVerificationGas
                || userOp.callGasLimit > maxCallGas || userOp.preVerificationGas > maxPreVerificationGas
                || userOp.maxPriorityFeePerGas > maxPriorityFeePerGas
                || userOp.maxFeePerGas > maxFeePerGas
                || !_legacyPaymasterPolicyAllows(account, userOp.paymasterAndData)
                || !_pluginCallAllowed(account, userOp.callData)
        ) return SIG_VALIDATION_FAILED;

        bytes32 digest = this.authorizationDigest(userOpHash);
        (address recovered, ECDSA.RecoverError err,) =
            ECDSA.tryRecoverCalldata(digest, userOp.signature);
        return err == ECDSA.RecoverError.NoError && isOwner(account, recovered)
            ? SIG_VALIDATION_PASSED
            : SIG_VALIDATION_FAILED;
    }

    function pluginManifest() external pure override returns (PluginManifest memory manifest) {
        manifest.dependencyInterfaceIds = new bytes4[](2);
        manifest.dependencyInterfaceIds[0] = type(IPlugin).interfaceId;
        manifest.dependencyInterfaceIds[1] = type(IPlugin).interfaceId;

        manifest.executionFunctions = new bytes4[](5);
        manifest.executionFunctions[0] = GrowYieldPlugin.executeGrowYield.selector;
        manifest.executionFunctions[1] =
            GrowYieldPlugin.executeGrowYieldWithEphemeralAllowance.selector;
        manifest.executionFunctions[2] = GrowYieldPlugin.supplyOnSpoke.selector;
        manifest.executionFunctions[3] = GrowYieldPlugin.withdrawOnSpoke.selector;
        manifest.executionFunctions[4] = GrowYieldPlugin.setSpokeCollateral.selector;

        ManifestFunction memory policyValidation = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.SELF,
            functionId: 0,
            dependencyIndex: 0
        });
        ManifestFunction memory denyRuntime = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.PRE_HOOK_ALWAYS_DENY,
            functionId: 0,
            dependencyIndex: 0
        });

        manifest.userOpValidationFunctions = new ManifestAssociatedFunction[](2);
        manifest.userOpValidationFunctions[0] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.executeGrowYield.selector,
            associatedFunction: policyValidation
        });
        manifest.userOpValidationFunctions[1] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.executeGrowYieldWithEphemeralAllowance.selector,
            associatedFunction: policyValidation
        });

        ManifestFunction memory spokeCallValidation = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.SELF,
            functionId: SPOKE_CALL_FUNCTION_ID,
            dependencyIndex: 0
        });
        manifest.runtimeValidationFunctions = new ManifestAssociatedFunction[](3);
        manifest.runtimeValidationFunctions[0] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.supplyOnSpoke.selector,
            associatedFunction: spokeCallValidation
        });
        manifest.runtimeValidationFunctions[1] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.withdrawOnSpoke.selector,
            associatedFunction: spokeCallValidation
        });
        manifest.runtimeValidationFunctions[2] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.setSpokeCollateral.selector,
            associatedFunction: spokeCallValidation
        });

        ManifestFunction memory noPostHook = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.NONE,
            functionId: 0,
            dependencyIndex: 0
        });
        manifest.executionHooks = new ManifestExecutionHook[](3);
        manifest.executionHooks[0] = ManifestExecutionHook({
            executionSelector: GrowYieldPlugin.supplyOnSpoke.selector,
            preExecHook: spokeCallValidation,
            postExecHook: noPostHook
        });
        manifest.executionHooks[1] = ManifestExecutionHook({
            executionSelector: GrowYieldPlugin.withdrawOnSpoke.selector,
            preExecHook: spokeCallValidation,
            postExecHook: noPostHook
        });
        manifest.executionHooks[2] = ManifestExecutionHook({
            executionSelector: GrowYieldPlugin.setSpokeCollateral.selector,
            preExecHook: spokeCallValidation,
            postExecHook: noPostHook
        });

        manifest.preRuntimeValidationHooks = new ManifestAssociatedFunction[](2);
        manifest.preRuntimeValidationHooks[0] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.executeGrowYield.selector,
            associatedFunction: denyRuntime
        });
        manifest.preRuntimeValidationHooks[1] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.executeGrowYieldWithEphemeralAllowance.selector,
            associatedFunction: denyRuntime
        });

        manifest.permitAnyExternalAddress = true;
    }

    /// @notice Selectors a Modular Account v2 installs so the executor can ask the account to
    ///         call an admitted spoke. `skipRuntimeValidation` is required because the executor
    ///         is not a validation module. The pre-exec hook rejects every other caller, and the
    ///         spoke functions still revert if that hook did not run.
    function executionManifest()
        external
        pure
        override
        returns (ExecutionManifest memory manifest)
    {
        manifest.executionFunctions = new Erc6900ExecutionFunction[](3);
        manifest.executionFunctions[0] = Erc6900ExecutionFunction({
            executionSelector: GrowYieldPlugin.supplyOnSpoke.selector,
            skipRuntimeValidation: true,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[1] = Erc6900ExecutionFunction({
            executionSelector: GrowYieldPlugin.withdrawOnSpoke.selector,
            skipRuntimeValidation: true,
            allowGlobalValidation: false
        });
        manifest.executionFunctions[2] = Erc6900ExecutionFunction({
            executionSelector: GrowYieldPlugin.setSpokeCollateral.selector,
            skipRuntimeValidation: true,
            allowGlobalValidation: false
        });

        manifest.executionHooks = new Erc6900ExecutionHook[](3);
        manifest.executionHooks[0] = Erc6900ExecutionHook({
            executionSelector: GrowYieldPlugin.supplyOnSpoke.selector,
            entityId: SPOKE_HOOK_ENTITY_ID,
            isPreHook: true,
            isPostHook: false
        });
        manifest.executionHooks[1] = Erc6900ExecutionHook({
            executionSelector: GrowYieldPlugin.withdrawOnSpoke.selector,
            entityId: SPOKE_HOOK_ENTITY_ID,
            isPreHook: true,
            isPostHook: false
        });
        manifest.executionHooks[2] = Erc6900ExecutionHook({
            executionSelector: GrowYieldPlugin.setSpokeCollateral.selector,
            entityId: SPOKE_HOOK_ENTITY_ID,
            isPreHook: true,
            isPostHook: false
        });

        manifest.interfaceIds = new bytes4[](0);
    }

    function pluginMetadata() external pure override returns (PluginMetadata memory metadata) {
        metadata.name = "Grow Yield Plugin";
        metadata.version = "1.0.0";
        metadata.author = "Grow";
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(BasePlugin, IERC165)
        returns (bool)
    {
        return interfaceId == type(IValidationModule).interfaceId
            || interfaceId == type(IExecutionModule).interfaceId
            || interfaceId == type(IExecutionHookModule).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _addOwner(address account, address owner) private {
        if (owner == address(0)) revert InvalidConfiguration();

        AccountConfig storage accountConfig = _accountConfigs[account];
        uint8 count = accountConfig.ownerCount;
        if (count == MAX_OWNERS) revert TooManyOwners();

        for (uint256 i; i < count; ++i) {
            if (accountConfig.owners[i] == owner) revert OwnerAlreadyExists();
        }

        accountConfig.owners[count] = owner;
        accountConfig.ownerCount = count + 1;
        emit OwnerAdded(account, owner);
    }

    function _setExecutor(address account, address executor) private {
        if (executor.code.length == 0 || executor == account) revert InvalidConfiguration();

        try IGrowYieldExecutor(executor).vaultCount() returns (uint256 vaults) {
            if (vaults == 0 || IGrowYieldExecutor(executor).riskGuardian() == address(0)) {
                revert InvalidConfiguration();
            }
        } catch {
            revert InvalidConfiguration();
        }

        _accountConfigs[account].executor = executor;
        emit ExecutorSet(account, executor);
    }

    function _setPaymaster(address account, address paymaster) private {
        if (paymaster.code.length == 0) revert InvalidConfiguration();

        _accountConfigs[account].paymaster = paymaster;
        emit PaymasterSet(account, paymaster);
    }

    function _clearAccountConfig(address account) private {
        AccountConfig storage accountConfig = _accountConfigs[account];
        if (accountConfig.entityId == 0) return;

        uint8 count = accountConfig.ownerCount;
        for (uint256 i; i < count; ++i) {
            address owner = accountConfig.owners[i];
            delete accountConfig.owners[i];
            emit OwnerRemoved(account, owner);
        }
        accountConfig.ownerCount = 0;
        accountConfig.entityId = 0;
        accountConfig.executor = address(0);
        accountConfig.paymaster = address(0);
        emit ExecutorSet(account, address(0));
        emit PaymasterSet(account, address(0));
    }

    function _requireSpokeCaller(address sender) private view {
        address executor = _accountConfigs[msg.sender].executor;
        if (executor == address(0)) revert PolicyNotInstalled();
        if (sender != executor) revert UnauthorizedExecutor();
    }

    /// @dev Consumes the executor hook, then allows the call only for an admitted Aave V4 venue.
    ///      `openingCollateral` is a deposit: it also requires an open deposit direction, an
    ///      unpaused venue, and a spoke the hub still lists. Turning collateral off and
    ///      withdrawing stay available after that listing view flips.
    function _admittedSpoke(address spoke, uint256 reserveId, bool openingCollateral)
        private
        returns (Venue memory admitted)
    {
        address account = msg.sender;
        address executor = _accountConfigs[account].executor;
        if (executor == address(0)) revert PolicyNotInstalled();
        if (_spokeCaller != account) revert UnauthorizedExecutor();
        _spokeCaller = address(0);

        IGrowYieldExecutor registry = IGrowYieldExecutor(executor);
        address vault = registry.aaveV4ReserveVenue(spoke, reserveId);
        admitted = registry.venue(vault);
        IAaveV4SpokeAdapter adapter = IAaveV4SpokeAdapter(admitted.adapter);
        if (
            admitted.adapter == address(0) || registry.vaultProtocol(vault) != Protocol.AAVE_V4
                || admitted.positionToken != vault || AaveV4ReserveVenue(vault).spoke() != spoke
                || AaveV4ReserveVenue(vault).reserveId() != reserveId
                || admitted.adapter.codehash != admitted.adapterCodeHash
                || adapter.executor() != executor
        ) revert SpokeNotAdmitted();

        if (openingCollateral) {
            if (!admitted.canDeposit) revert IGrowYieldExecutor.VenueNotAllowed();
            if (registry.allDepositsPaused() || registry.depositsPaused(vault)) {
                revert IGrowYieldExecutor.DepositsPaused();
            }
            if (!adapter.spokeListed(vault) || adapter.asset(vault) != admitted.asset) {
                revert IGrowYieldExecutor.VenueDrift();
            }
        } else if (!admitted.canRedeem) {
            revert IGrowYieldExecutor.VenueNotAllowed();
        }
    }

    function _approveFromAccount(address account, address token, address spender, uint256 amount)
        private
    {
        bytes memory ret =
            _callFromAccount(account, token, abi.encodeCall(IERC20.approve, (spender, amount)));
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert SpokeApprovalFailed();
    }

    /// @dev The account performs the call. Aave therefore sees the account as `msg.sender`.
    function _callFromAccount(address account, address target, bytes memory data)
        private
        returns (bytes memory)
    {
        return IModularAccount(account).execute(target, 0, data);
    }

    /// @dev UserOp validation is not the only way into an execution function: `executeFromPlugin`
    ///      runs pre-execution hooks only, so the manifest's `PRE_HOOK_ALWAYS_DENY` pre-runtime
    ///      hooks never see that path. Re-checking here keeps `permitAnyExternalAddress` pointed at
    ///      the one executor the account approved, whatever route reached this call.
    function _requireApprovedExecutor(address executor) private view {
        address approved = _accountConfigs[msg.sender].executor;
        if (approved == address(0)) revert PolicyNotInstalled();
        if (executor != approved) revert UnauthorizedExecutor();
    }

    function _gasPolicyAllows(PackedUserOperation calldata userOp) private view returns (bool) {
        return userOp.unpackVerificationGasLimit() <= maxVerificationGas
            && userOp.unpackCallGasLimit() <= maxCallGas
            && userOp.preVerificationGas <= maxPreVerificationGas
            && userOp.unpackMaxPriorityFeePerGas() <= maxPriorityFeePerGas
            && userOp.unpackMaxFeePerGas() <= maxFeePerGas;
    }

    /// @dev EntryPoint v0.7 layout, which is positional and not negotiable: `[0:20)` paymaster,
    ///      `[20:36)` paymaster verification gas, `[36:52)` paymaster postOp gas, `[52:)` paymaster
    ///      data. The two gas fields sit at those offsets no matter what the paymaster appends after
    ///      them — a verifying paymaster's `validUntil`/`validAfter` and signature start at 52 — so
    ///      both ceilings apply to every operation, however long `paymasterAndData` is.
    function _paymasterPolicyAllows(address account, bytes calldata paymasterAndData)
        private
        view
        returns (bool)
    {
        if (
            paymasterAndData.length < PAYMASTER_DATA_OFFSET
                || paymasterAndData.length > MAX_PAYMASTER_AND_DATA_LENGTH
                || address(bytes20(paymasterAndData[:20])) != _accountConfigs[account].paymaster
        ) return false;

        return uint128(bytes16(paymasterAndData[20:36])) <= maxPaymasterVerificationGas
            && uint128(bytes16(paymasterAndData[36:52])) <= maxPaymasterPostOpGas;
    }

    /// @dev EntryPoint v0.6 layout: `[0:20)` paymaster, `[20:)` paymaster data. A v0.6
    ///      UserOperation carries no paymaster gas limits, so there is nothing for
    ///      `maxPaymasterVerificationGas` / `maxPaymasterPostOpGas` to bound on this path and the
    ///      minimum length is the address alone. Reading bytes `[20:52)` as gas limits here would
    ///      be reading a Gas Manager's timestamps and signature.
    function _legacyPaymasterPolicyAllows(address account, bytes calldata paymasterAndData)
        private
        view
        returns (bool)
    {
        return paymasterAndData.length >= PAYMASTER_ADDRESS_LENGTH
            && paymasterAndData.length <= MAX_PAYMASTER_AND_DATA_LENGTH
            && address(bytes20(paymasterAndData[:20])) == _accountConfigs[account].paymaster;
    }

    function _pluginCallAllowed(address account, bytes calldata callData)
        private
        view
        returns (bool)
    {
        if (callData.length < 4) return false;

        bytes4 selector = bytes4(callData[:4]);
        address executor;
        bytes memory inner;

        if (selector == this.executeGrowYield.selector) {
            (executor, inner) = abi.decode(callData[4:], (address, bytes));
        } else if (selector == this.executeGrowYieldWithEphemeralAllowance.selector) {
            Operation[] memory ops;
            (executor, ops) = abi.decode(callData[4:], (address, Operation[]));
            inner = abi.encodeCall(IGrowYieldExecutor.execute, (ops));
        } else {
            return false;
        }

        bytes memory executeCallData =
            abi.encodeCall(IStandardExecutor.execute, (executor, uint256(0), inner));
        try this.isAllowedCallData(account, executeCallData) returns (bool allowed) {
            return allowed;
        } catch {
            return false;
        }
    }
}
