// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {
    PackedUserOperation
} from "@eth-infinitism/account-abstraction/interfaces/PackedUserOperation.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {
    IValidationModule
} from "@erc6900/reference-implementation/interfaces/IValidationModule.sol";
import {BaseModule} from "@erc6900/reference-implementation/modules/BaseModule.sol";
import {ReplaySafeWrapper} from "@erc6900/reference-implementation/modules/ReplaySafeWrapper.sol";
import {
    ISingleSignerValidationModule
} from "@erc6900/reference-implementation/modules/validation/ISingleSignerValidationModule.sol";

/// @notice Models Alchemy v2.0.x SingleSignerValidationModule signature framing.
/// @dev The first signature byte selects EOA (`0`) or ERC-1271 contract (`1`).
contract AlchemySingleSignerValidationModuleHarness is
    ISingleSignerValidationModule,
    ReplaySafeWrapper,
    BaseModule
{
    using MessageHashUtils for bytes32;

    uint256 private constant SIG_VALIDATION_PASSED = 0;
    uint256 private constant SIG_VALIDATION_FAILED = 1;
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 private constant ERC1271_INVALID = 0xffffffff;

    mapping(uint32 entityId => mapping(address account => address)) public signers;

    function transferSigner(uint32 entityId, address newSigner) external {
        _transferSigner(entityId, newSigner);
    }

    function onInstall(bytes calldata data) external override {
        (uint32 entityId, address newSigner) = abi.decode(data, (uint32, address));
        _transferSigner(entityId, newSigner);
    }

    function onUninstall(bytes calldata data) external override {
        uint32 entityId = abi.decode(data, (uint32));
        _transferSigner(entityId, address(0));
    }

    function validateUserOp(
        uint32 entityId,
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) external view override returns (uint256) {
        return _checkSignature(
            signers[entityId][userOp.sender], userOpHash.toEthSignedMessageHash(), userOp.signature
        )
            ? SIG_VALIDATION_PASSED
            : SIG_VALIDATION_FAILED;
    }

    function validateRuntime(
        address account,
        uint32 entityId,
        address sender,
        uint256,
        bytes calldata,
        bytes calldata
    ) external view override {
        if (sender != signers[entityId][account]) revert NotAuthorized();
    }

    function validateSignature(
        address account,
        uint32 entityId,
        address,
        bytes32 digest,
        bytes calldata signature
    ) external view override returns (bytes4) {
        bytes32 replaySafeDigest = replaySafeHash(account, digest);
        return _checkSignature(signers[entityId][account], replaySafeDigest, signature)
            ? ERC1271_MAGIC
            : ERC1271_INVALID;
    }

    function moduleId() external pure returns (string memory) {
        return "alchemy.single-signer-validation-module.1.0.0-harness";
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(BaseModule, IERC165)
        returns (bool)
    {
        return interfaceId == type(IValidationModule).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function _transferSigner(uint32 entityId, address newSigner) private {
        address previousSigner = signers[entityId][msg.sender];
        signers[entityId][msg.sender] = newSigner;
        emit SignerTransferred(msg.sender, entityId, newSigner, previousSigner);
    }

    function _checkSignature(address signer, bytes32 digest, bytes calldata signature)
        private
        view
        returns (bool)
    {
        if (signature.length < 1) return false;

        uint8 signatureType = uint8(signature[0]);
        if (signatureType == 0) {
            (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature[1:]);
            return err == ECDSA.RecoverError.NoError && recovered == signer;
        }
        if (signatureType == 1) {
            return
                SignatureChecker.isValidERC1271SignatureNowCalldata(signer, digest, signature[1:]);
        }
        return false;
    }
}
