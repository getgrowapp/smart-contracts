// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {_packValidationData} from "@eth-infinitism/account-abstraction/core/Helpers.sol";
import {UserOperationLib} from "@eth-infinitism/account-abstraction/core/UserOperationLib.sol";
import {
    IValidationModule
} from "@erc6900/reference-implementation/interfaces/IValidationModule.sol";
import {IModule} from "@erc6900/reference-implementation/interfaces/IModule.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {UserOperation} from "@alchemy/msca/interfaces/erc4337/UserOperation.sol";
import {
    ManifestFunction,
    ManifestAssociatedFunctionType,
    ManifestAssociatedFunction,
    PluginManifest,
    PluginMetadata,
    IPlugin
} from "@alchemy/msca/interfaces/IPlugin.sol";
import {IPluginExecutor} from "@alchemy/msca/interfaces/IPluginExecutor.sol";
import {IStandardExecutor} from "@alchemy/msca/interfaces/IStandardExecutor.sol";
import {SIG_VALIDATION_PASSED, SIG_VALIDATION_FAILED} from "@alchemy/msca/libraries/Constants.sol";
import {BasePlugin} from "@alchemy/msca/plugins/BasePlugin.sol";

import {IGrowYieldExecutor, Operation} from "./interfaces/IGrowYieldExecutor.sol";
import {IGrowYieldPolicyModule} from "./interfaces/IGrowYieldPolicyModule.sol";
import {GrowYieldPluginEphemeralLib} from "./GrowYieldPluginEphemeralLib.sol";
import {GrowYieldPolicyLib} from "./GrowYieldPolicyLib.sol";

/// @title GrowYieldPlugin
/// @notice MSCA plugin and ERC-6900 validation module for policy-owner-authorized yield operations.
/// @custom:security-contact security@getgrowapp.co
contract GrowYieldPlugin is IGrowYieldPolicyModule, BasePlugin, EIP712 {
    using UserOperationLib for PackedUserOperation;

    uint256 private constant SIGNATURE_LENGTH = 65;
    uint256 private constant PAYMASTER_STATIC_FIELDS_LENGTH = 52;
    uint256 private constant MAX_PAYMASTER_AND_DATA_LENGTH = 512;

    bytes4 private constant ERC1271_INVALID = 0xffffffff;
    bytes32 private constant AUTHORIZATION_TYPEHASH =
        keccak256("GrowYieldAuthorization(bytes32 userOpHash)");

    uint8 public constant MAX_OWNERS = 8;

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

    function executeGrowYield(address executor, bytes calldata executorCallData) external returns (bytes memory) {
        return IPluginExecutor(msg.sender).executeFromPluginExternal(executor, 0, executorCallData);
    }

    /// @notice Approve the executor per unique `sourceToken`, run `executor.execute(ops)`, then revoke.
    function executeGrowYieldWithEphemeralAllowance(address executor, Operation[] calldata ops)
        external
        returns (bytes memory)
    {
        return GrowYieldPluginEphemeralLib.executeWithEphemeralAllowance(executor, ops);
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
        return
            accountExecutor_ != address(0)
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

    function userOpValidationFunction(uint8 functionId, UserOperation calldata userOp, bytes32 userOpHash)
        external
        view
        override
        returns (uint256)
    {
        if (functionId != 0) revert NotImplemented(msg.sig, functionId);

        address account = msg.sender;
        if (
            _accountConfigs[account].entityId == 0 || userOp.signature.length != SIGNATURE_LENGTH
                || userOp.initCode.length != 0
                || userOp.verificationGasLimit > maxVerificationGas
                || userOp.callGasLimit > maxCallGas
                || userOp.preVerificationGas > maxPreVerificationGas
                || userOp.maxPriorityFeePerGas > maxPriorityFeePerGas
                || userOp.maxFeePerGas > maxFeePerGas
                || !_mscaPaymasterAllowed(account, userOp.paymasterAndData)
                || !_pluginCallAllowed(account, userOp.callData)
        ) return SIG_VALIDATION_FAILED;

        bytes32 digest = this.authorizationDigest(userOpHash);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, userOp.signature);
        return err == ECDSA.RecoverError.NoError && isOwner(account, recovered)
            ? SIG_VALIDATION_PASSED
            : SIG_VALIDATION_FAILED;
    }

    function pluginManifest() external pure override returns (PluginManifest memory manifest) {
        manifest.dependencyInterfaceIds = new bytes4[](2);
        manifest.dependencyInterfaceIds[0] = type(IPlugin).interfaceId;
        manifest.dependencyInterfaceIds[1] = type(IPlugin).interfaceId;

        manifest.executionFunctions = new bytes4[](2);
        manifest.executionFunctions[0] = GrowYieldPlugin.executeGrowYield.selector;
        manifest.executionFunctions[1] = GrowYieldPlugin.executeGrowYieldWithEphemeralAllowance.selector;

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
            || super.supportsInterface(interfaceId);
    }

    function _onInstall(bytes calldata data) internal override isNotInitialized(msg.sender) {
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

    function _isInitialized(address account) internal view override returns (bool) {
        return _accountConfigs[account].entityId != 0;
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

    function _gasPolicyAllows(PackedUserOperation calldata userOp) private view returns (bool) {
        return userOp.unpackVerificationGasLimit() <= maxVerificationGas
            && userOp.unpackCallGasLimit() <= maxCallGas
            && userOp.preVerificationGas <= maxPreVerificationGas
            && userOp.unpackMaxPriorityFeePerGas() <= maxPriorityFeePerGas
            && userOp.unpackMaxFeePerGas() <= maxFeePerGas;
    }

    function _paymasterPolicyAllows(address account, bytes calldata paymasterAndData)
        private
        view
        returns (bool)
    {
        if (
            paymasterAndData.length < PAYMASTER_STATIC_FIELDS_LENGTH
                || paymasterAndData.length > MAX_PAYMASTER_AND_DATA_LENGTH
                || address(bytes20(paymasterAndData[:20])) != _accountConfigs[account].paymaster
        ) return false;

        // Alchemy Gas Manager appends validUntil + signature after the paymaster address.
        // Bytes [20:52) are not verification/postOp gas limits in that encoding.
        if (paymasterAndData.length > PAYMASTER_STATIC_FIELDS_LENGTH) return true;

        return uint128(bytes16(paymasterAndData[20:36])) <= maxPaymasterVerificationGas
            && uint128(bytes16(paymasterAndData[36:52])) <= maxPaymasterPostOpGas;
    }

    function _pluginCallAllowed(address account, bytes calldata callData) private view returns (bool) {
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

    function _mscaPaymasterAllowed(address account, bytes calldata paymasterAndData) private view returns (bool) {
        return _paymasterPolicyAllows(account, paymasterAndData);
    }
}
