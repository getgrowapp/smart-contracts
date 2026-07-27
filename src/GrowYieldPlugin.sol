// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
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

import {GrowYieldPolicyModule} from "./GrowYieldPolicyModule.sol";

/// @title GrowYieldPlugin
/// @notice MSCA plugin: policy state + EIP-712 live on `policyModule`; this adds MSCA validation routing.
contract GrowYieldPlugin is BasePlugin {
    uint256 private constant SIGNATURE_LENGTH = 65;
    uint256 private constant PAYMASTER_HEAD = 52;

    GrowYieldPolicyModule public immutable policyModule;

    constructor(GrowYieldPolicyModule policyModule_) {
        policyModule = policyModule_;
    }

    function executeGrowYield(address executor, bytes calldata executorCallData) external returns (bytes memory) {
        return IPluginExecutor(msg.sender).executeFromPluginExternal(executor, 0, executorCallData);
    }

    function onUninstall(bytes calldata) external override {
        IPluginExecutor(msg.sender).executeFromPluginExternal(
            address(policyModule), 0, abi.encodeCall(GrowYieldPolicyModule.onUninstall, (""))
        );
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
            policyModule.policyEntityId(account) == 0 || userOp.signature.length != SIGNATURE_LENGTH
                || userOp.initCode.length != 0
                || userOp.verificationGasLimit > policyModule.maxVerificationGas()
                || userOp.callGasLimit > policyModule.maxCallGas()
                || userOp.preVerificationGas > policyModule.maxPreVerificationGas()
                || userOp.maxPriorityFeePerGas > policyModule.maxPriorityFeePerGas()
                || userOp.maxFeePerGas > policyModule.maxFeePerGas()
                || !_paymasterAllowed(account, userOp.paymasterAndData)
                || !_pluginCallAllowed(account, userOp.callData)
        ) return SIG_VALIDATION_FAILED;

        bytes32 digest = policyModule.authorizationDigest(userOpHash);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecoverCalldata(digest, userOp.signature);
        return err == ECDSA.RecoverError.NoError && policyModule.isOwner(account, recovered)
            ? SIG_VALIDATION_PASSED
            : SIG_VALIDATION_FAILED;
    }

    function pluginManifest() external pure override returns (PluginManifest memory manifest) {
        manifest.dependencyInterfaceIds = new bytes4[](2);
        manifest.dependencyInterfaceIds[0] = type(IPlugin).interfaceId;
        manifest.dependencyInterfaceIds[1] = type(IPlugin).interfaceId;

        manifest.executionFunctions = new bytes4[](1);
        manifest.executionFunctions[0] = GrowYieldPlugin.executeGrowYield.selector;

        ManifestFunction memory policyValidation = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.SELF,
            functionId: 0,
            dependencyIndex: 0
        });
        manifest.userOpValidationFunctions = new ManifestAssociatedFunction[](1);
        manifest.userOpValidationFunctions[0] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.executeGrowYield.selector,
            associatedFunction: policyValidation
        });

        manifest.preRuntimeValidationHooks = new ManifestAssociatedFunction[](1);
        manifest.preRuntimeValidationHooks[0] = ManifestAssociatedFunction({
            executionSelector: GrowYieldPlugin.executeGrowYield.selector,
            associatedFunction: ManifestFunction({
                functionType: ManifestAssociatedFunctionType.PRE_HOOK_ALWAYS_DENY,
                functionId: 0,
                dependencyIndex: 0
            })
        });

        manifest.permitAnyExternalAddress = true;
    }

    function pluginMetadata() external pure override returns (PluginMetadata memory metadata) {
        metadata.name = "Grow Yield Plugin";
        metadata.version = "1.0.0";
        metadata.author = "Grow";
    }

    function _onInstall(bytes calldata data) internal override isNotInitialized(msg.sender) {
        IPluginExecutor(msg.sender).executeFromPluginExternal(
            address(policyModule), 0, abi.encodeCall(GrowYieldPolicyModule.onInstall, (data))
        );
    }

    function _isInitialized(address account) internal view override returns (bool) {
        return policyModule.policyEntityId(account) != 0;
    }

    function _pluginCallAllowed(address account, bytes calldata callData) private view returns (bool) {
        if (callData.length < 4 || bytes4(callData[:4]) != this.executeGrowYield.selector) return false;
        (address executor, bytes memory inner) = abi.decode(callData[4:], (address, bytes));
        bytes memory executeCallData =
            abi.encodeCall(IStandardExecutor.execute, (executor, uint256(0), inner));
        try policyModule.isAllowedCallData(account, executeCallData) returns (bool allowed) {
            return allowed;
        } catch {
            return false;
        }
    }

    function _paymasterAllowed(address account, bytes calldata paymasterAndData) private view returns (bool) {
        address paymaster = policyModule.accountPaymaster(account);
        if (paymaster == address(0) || paymasterAndData.length < PAYMASTER_HEAD) return false;
        if (address(bytes20(paymasterAndData[:20])) != paymaster) return false;
        return uint128(bytes16(paymasterAndData[20:36])) <= policyModule.maxPaymasterVerificationGas()
            && uint128(bytes16(paymasterAndData[36:52])) <= policyModule.maxPaymasterPostOpGas();
    }
}
