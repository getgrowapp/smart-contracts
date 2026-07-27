// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {_packValidationData} from "@eth-infinitism/account-abstraction/core/Helpers.sol";
import {UserOperationLib} from "@eth-infinitism/account-abstraction/core/UserOperationLib.sol";
import {BaseModule} from "@erc6900/reference-implementation/modules/BaseModule.sol";
import {
    IValidationModule
} from "@erc6900/reference-implementation/interfaces/IValidationModule.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

import {IGrowYieldAdapterRegistry} from "./interfaces/IGrowYieldAdapterRegistry.sol";
import {IGrowYieldExecutor} from "./interfaces/IGrowYieldExecutor.sol";
import {IGrowYieldPolicyModule} from "./interfaces/IGrowYieldPolicyModule.sol";
import {GrowYieldPolicyLib} from "./GrowYieldPolicyLib.sol";

/// @title GrowYieldPolicyModule
/// @notice Validates sponsor-paid yield UserOperations signed by an account's policy owners.
/// @dev Validation uses only ECDSA recovery, immutable policy limits, and account-associated
///      storage.
/// @custom:security-contact security@getgrowapp.co
contract GrowYieldPolicyModule is IGrowYieldPolicyModule, BaseModule, EIP712 {
    using UserOperationLib for PackedUserOperation;

    uint256 private constant SIGNATURE_LENGTH = 65;
    uint256 private constant PAYMASTER_STATIC_FIELDS_LENGTH = 52;
    uint256 private constant MAX_PAYMASTER_AND_DATA_LENGTH = 512;

    bytes4 private constant ERC1271_INVALID = 0xffffffff;
    bytes32 private constant AUTHORIZATION_TYPEHASH =
        keccak256("GrowYieldAuthorization(bytes32 userOpHash)");

    /// @notice Maximum policy owners stored in account-associated consecutive slots.
    uint8 public constant MAX_OWNERS = 8;

    /// @inheritdoc IGrowYieldPolicyModule
    address public immutable requiredPaymaster;

    /// @notice Maximum account verification gas accepted by the policy.
    uint128 public immutable maxVerificationGas;

    /// @notice Maximum account call gas accepted by the policy.
    uint128 public immutable maxCallGas;

    /// @notice Maximum pre-verification gas accepted by the policy.
    uint256 public immutable maxPreVerificationGas;

    /// @notice Maximum paymaster verification gas accepted by the policy.
    uint128 public immutable maxPaymasterVerificationGas;

    /// @notice Maximum paymaster post-operation gas accepted by the policy.
    uint128 public immutable maxPaymasterPostOpGas;

    /// @notice Maximum priority fee accepted by the policy.
    uint128 public immutable maxPriorityFeePerGas;

    /// @notice Maximum total fee accepted by the policy.
    uint128 public immutable maxFeePerGas;

    /// @dev Solidity lays this structure at `keccak(account || slot) + n`, with
    ///      every validation read inside ERC-7562's 0..128 associated-slot range.
    struct AccountConfig {
        uint32 entityId;
        uint8 count;
        address executor;
        address[MAX_OWNERS] owners;
    }

    mapping(address account => AccountConfig) private _accountConfigs;

    /// @dev Pins the required paymaster and all gas/fee ceilings immutably. The executor is
    ///      per-account and account-settable, so it is not fixed here.
    constructor(
        address requiredPaymaster_,
        uint128 maxVerificationGas_,
        uint128 maxCallGas_,
        uint256 maxPreVerificationGas_,
        uint128 maxPaymasterVerificationGas_,
        uint128 maxPaymasterPostOpGas_,
        uint128 maxPriorityFeePerGas_,
        uint128 maxFeePerGas_
    ) EIP712("GrowYieldPolicy", "1") {
        if (
            requiredPaymaster_.code.length == 0 || maxVerificationGas_ == 0 || maxCallGas_ == 0
                || maxPreVerificationGas_ == 0 || maxPaymasterVerificationGas_ == 0
                || maxPaymasterPostOpGas_ == 0 || maxFeePerGas_ == 0
                || maxPriorityFeePerGas_ > maxFeePerGas_
        ) revert InvalidConfiguration();

        requiredPaymaster = requiredPaymaster_;
        maxVerificationGas = maxVerificationGas_;
        maxCallGas = maxCallGas_;
        maxPreVerificationGas = maxPreVerificationGas_;
        maxPaymasterVerificationGas = maxPaymasterVerificationGas_;
        maxPaymasterPostOpGas = maxPaymasterPostOpGas_;
        maxPriorityFeePerGas = maxPriorityFeePerGas_;
        maxFeePerGas = maxFeePerGas_;
    }

    /// @inheritdoc IGrowYieldPolicyModule
    function addOwner(address owner) external {
        if (_accountConfigs[msg.sender].entityId == 0) revert PolicyNotInstalled();
        _addOwner(msg.sender, owner);
    }

    /// @inheritdoc IGrowYieldPolicyModule
    function removeOwner(address owner) external {
        AccountConfig storage accountConfig = _accountConfigs[msg.sender];
        if (accountConfig.entityId == 0) revert PolicyNotInstalled();
        uint8 count = accountConfig.count;

        for (uint256 i; i < count; ++i) {
            if (accountConfig.owners[i] != owner) continue;

            uint8 last = count - 1;
            if (i != last) accountConfig.owners[i] = accountConfig.owners[last];
            delete accountConfig.owners[last];
            accountConfig.count = last;
            emit OwnerRemoved(msg.sender, owner);
            return;
        }

        revert OwnerNotFound();
    }

    /// @inheritdoc IGrowYieldPolicyModule
    function isOwner(address account, address owner) public view returns (bool) {
        AccountConfig storage accountConfig = _accountConfigs[account];
        uint8 count = accountConfig.count;
        for (uint256 i; i < count; ++i) {
            if (accountConfig.owners[i] == owner) return true;
        }
        return false;
    }

    /// @inheritdoc IGrowYieldPolicyModule
    function ownerCount(address account) external view returns (uint8) {
        return _accountConfigs[account].count;
    }

    /// @inheritdoc IGrowYieldPolicyModule
    function ownerAt(address account, uint256 index) external view returns (address) {
        if (index >= _accountConfigs[account].count) revert OwnerNotFound();
        return _accountConfigs[account].owners[index];
    }

    /// @inheritdoc IGrowYieldPolicyModule
    function policyEntityId(address account) external view returns (uint32) {
        return _accountConfigs[account].entityId;
    }

    /// @inheritdoc IGrowYieldPolicyModule
    function setExecutor(address executor) external {
        AccountConfig storage accountConfig = _accountConfigs[msg.sender];
        if (accountConfig.entityId == 0) revert PolicyNotInstalled();
        _setExecutor(msg.sender, executor);
    }

    /// @inheritdoc IGrowYieldPolicyModule
    function accountExecutor(address account) external view returns (address) {
        return _accountConfigs[account].executor;
    }

    /// @inheritdoc IValidationModule
    function validateUserOp(
        uint32 entityId,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external view override returns (uint256) {
        bool valid = entityId != 0 && entityId == _accountConfigs[userOp.sender].entityId
            && msg.sender == userOp.sender && userOp.signature.length == SIGNATURE_LENGTH;

        if (valid) {
            valid = userOp.initCode.length == 0 && _gasPolicyAllows(userOp)
                && _paymasterPolicyAllows(userOp.paymasterAndData);
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

    /// @notice Return whether calldata satisfies the canonical yield policy.
    /// @dev Externalized so malformed ABI can be contained without reverting validation.
    function isAllowedCallData(address account, bytes calldata callData)
        external
        view
        returns (bool)
    {
        address accountExecutor_ = _accountConfigs[account].executor;
        return accountExecutor_ != address(0)
            && GrowYieldPolicyLib.isAllowed(account, accountExecutor_, callData);
    }

    /// @inheritdoc IValidationModule
    function validateRuntime(address, uint32, address, uint256, bytes calldata, bytes calldata)
        external
        pure
        override
    {
        revert NotImplemented();
    }

    /// @inheritdoc IValidationModule
    function validateSignature(address, uint32, address, bytes32, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return ERC1271_INVALID;
    }

    /// @notice Configure the installing account's entity, policy-owner set, and executor.
    /// @dev One Grow entity is supported per account. Uninstall it before choosing another.
    ///      This single call is the account's whole opt-in: the executor names the registry, the
    ///      registry names the venues, and there is nothing further to configure per venue.
    function onInstall(bytes calldata data) external override {
        if (_accountConfigs[msg.sender].entityId != 0) revert PolicyAlreadyInstalled();

        (uint32 entityId, address[] memory initialOwners, address executor) =
            abi.decode(data, (uint32, address[], address));
        if (entityId == 0 || initialOwners.length == 0 || initialOwners.length > MAX_OWNERS) {
            revert InvalidConfiguration();
        }

        _accountConfigs[msg.sender].entityId = entityId;
        for (uint256 i; i < initialOwners.length; ++i) {
            _addOwner(msg.sender, initialOwners[i]);
        }
        _setExecutor(msg.sender, executor);
    }

    /// @notice Clear the uninstalling account's entity and policy-owner set.
    function onUninstall(bytes calldata) external override {
        _clearAccountConfig(msg.sender);
    }

    /// @notice Return this module's semantic identifier.
    function moduleId() external pure returns (string memory) {
        return "grow.yield-policy.4.0.0";
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(BaseModule, IERC165)
        returns (bool)
    {
        return interfaceId == type(IValidationModule).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @dev Appends a unique nonzero owner below the `MAX_OWNERS` bound.
    function _addOwner(address account, address owner) private {
        if (owner == address(0)) revert InvalidConfiguration();

        AccountConfig storage accountConfig = _accountConfigs[account];
        uint8 count = accountConfig.count;
        if (count == MAX_OWNERS) revert TooManyOwners();

        for (uint256 i; i < count; ++i) {
            if (accountConfig.owners[i] == owner) revert OwnerAlreadyExists();
        }

        accountConfig.owners[count] = owner;
        accountConfig.count = count + 1;
        emit OwnerAdded(account, owner);
    }

    /// @dev Pins the single executor whose `execute` batches this account's policy accepts.
    ///
    ///      This address is load-bearing well beyond routing: once set, a policy owner (session
    ///      key) can sign a batch that approves it for the account's full balance and calls
    ///      `execute` on it with arbitrary operations. An owner typo here would therefore
    ///      become a session-key-exploitable drain, so the address must prove it is a Grow
    ///      executor bound to a registry that names it back — a property no arbitrary contract
    ///      can fake without deploying the real pair.
    function _setExecutor(address account, address executor) private {
        if (executor.code.length == 0) revert InvalidConfiguration();

        try IGrowYieldExecutor(executor).registry() returns (IGrowYieldAdapterRegistry registry) {
            // A non-conforming registry reverts loudly here; this is an owner-path call, so
            // failing the transaction is the right outcome either way.
            if (address(registry) == address(0) || registry.executor() != executor) {
                revert InvalidConfiguration();
            }
        } catch {
            revert InvalidConfiguration();
        }

        _accountConfigs[account].executor = executor;
        emit ExecutorSet(account, executor);
    }

    /// @dev Deletes the account's entity, executor, and every stored policy owner.
    function _clearAccountConfig(address account) private {
        AccountConfig storage accountConfig = _accountConfigs[account];
        uint8 count = accountConfig.count;
        for (uint256 i; i < count; ++i) {
            address owner = accountConfig.owners[i];
            delete accountConfig.owners[i];
            emit OwnerRemoved(account, owner);
        }
        accountConfig.count = 0;
        accountConfig.entityId = 0;
        accountConfig.executor = address(0);
        emit ExecutorSet(account, address(0));
    }

    /// @dev True if every account gas and fee field is within the policy ceilings.
    function _gasPolicyAllows(PackedUserOperation calldata userOp) private view returns (bool) {
        return userOp.unpackVerificationGasLimit() <= maxVerificationGas
            && userOp.unpackCallGasLimit() <= maxCallGas
            && userOp.preVerificationGas <= maxPreVerificationGas
            && userOp.unpackMaxPriorityFeePerGas() <= maxPriorityFeePerGas
            && userOp.unpackMaxFeePerGas() <= maxFeePerGas;
    }

    /// @dev True if the required paymaster is used within its gas ceilings.
    function _paymasterPolicyAllows(bytes calldata paymasterAndData) private view returns (bool) {
        if (
            paymasterAndData.length < PAYMASTER_STATIC_FIELDS_LENGTH
                || paymasterAndData.length > MAX_PAYMASTER_AND_DATA_LENGTH
                || address(bytes20(paymasterAndData[:20])) != requiredPaymaster
        ) return false;

        return uint128(bytes16(paymasterAndData[20:36])) <= maxPaymasterVerificationGas
            && uint128(bytes16(paymasterAndData[36:52])) <= maxPaymasterPostOpGas;
    }
}
