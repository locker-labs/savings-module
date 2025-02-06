// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {BasePlugin} from "./plugins/BasePlugin.sol";
import {IPluginExecutor} from "./interfaces/IPluginExecutor.sol";
import {IStandardExecutor} from "./interfaces/IStandardExecutor.sol";
import {ManifestFunction, ManifestExecutionHook, ManifestAssociatedFunctionType, ManifestAssociatedFunction, PluginManifest, PluginMetadata, IPlugin} from "./interfaces/IPlugin.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {UserOperation} from "./interfaces/erc4337/UserOperation.sol";
import {SIG_VALIDATION_PASSED
} from "./libraries/Constants.sol";
enum FunctionId {
    EXECUTE_FUNCTION,
    EXECUTE_BATCH_FUNCTION
}

/// @title Savings Plugin
/// @author Locker
/// @notice This plugin lets users automatically save when making payments
contract SavingsPlugin is BasePlugin {
    string public constant NAME = "Locker Savings Plugin";
    string public constant VERSION = "0.0.2";
    string public constant AUTHOR = "Locker Team";

// Declare dependency indices to mirror SessionKey:
    uint256 internal constant _MANIFEST_DEPENDENCY_INDEX_OWNER_RUNTIME_VALIDATION = 0;
    uint256 internal constant _MANIFEST_DEPENDENCY_INDEX_OWNER_USER_OP_VALIDATION = 1;
    struct SavingsAutomation {
        address savingsAccount;
        uint256 roundUpTo;
        bool enabled;
    }

    mapping(address => mapping(uint256 => SavingsAutomation)) public savingsAutomations;

    function createAutomation(
        uint256 automationIndex,
        address savingsAccount,
        uint256 roundUpTo
    ) external {
        savingsAutomations[msg.sender][automationIndex] = SavingsAutomation(
            savingsAccount,
            roundUpTo,
            true
        );
    }

    function onInstall(bytes calldata) external pure override {}

    function onUninstall(bytes calldata) external pure override {}

    function preExecutionHook(
        uint8 functionId,
        address,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes memory) {
        SavingsAutomation memory automation = savingsAutomations[msg.sender][0];
        if (automation.enabled && automation.roundUpTo > 0 && data.length >= 4) {
            uint256 roundUpTo = automation.roundUpTo;
            (address tokenAddress, uint256 ethValue, bytes memory innerData) = abi.decode(
                data[4:],
                (address, uint256, bytes)
            );
            bytes4 transferSelector;
            address recipient;
            uint256 transferAmount;
            assembly {
                transferSelector := mload(add(innerData, 32))
                recipient := mload(add(innerData, 36))
                transferAmount := mload(add(innerData, 68))
            }
            uint256 roundUpAmount = ((transferAmount + roundUpTo - 1) / roundUpTo) * roundUpTo;
            uint256 savingsAmount = roundUpAmount - transferAmount;
            if (savingsAmount > 0) {
                IPluginExecutor(msg.sender).executeFromPluginExternal(
                    tokenAddress,
                    0,
                    abi.encodeWithSelector(
                        IERC20.transfer.selector,
                        automation.savingsAccount,
                        savingsAmount
                    )
                );
            }
        }
        return "";
    }

    /// @notice This function is overridden solely to satisfy the BasePlugin interface.
    /// @dev Since validation is delegated to the MultiOwner plugin, this function should never be called.
    function userOpValidationFunction(
        uint8, // functionId
        UserOperation calldata, // userOp
        bytes32              // userOpHash
    ) external pure override returns (uint256) {
        revert("SavingsPlugin: use dependency for validation");
    }

    /// @notice Plugin manifest describing this plugin's functions and validations.
    /// @dev The manifest delegates both userOp and runtime validation to a dependency at index 0.
    function pluginManifest() external pure override returns (PluginManifest memory manifest) {
        // Declare two dependencies.
        manifest.dependencyInterfaceIds = new bytes4[](2);
        manifest.dependencyInterfaceIds[_MANIFEST_DEPENDENCY_INDEX_OWNER_RUNTIME_VALIDATION] = type(IPlugin).interfaceId;
        manifest.dependencyInterfaceIds[_MANIFEST_DEPENDENCY_INDEX_OWNER_USER_OP_VALIDATION] = type(IPlugin).interfaceId;

        // List the execution functions provided by this plugin.
        manifest.executionFunctions = new bytes4[](1);
        manifest.executionFunctions[0] = this.createAutomation.selector;

        // Delegate user operation validation to the dependency in slot 1.
        manifest.userOpValidationFunctions = new ManifestAssociatedFunction[](1);
        manifest.userOpValidationFunctions[0] = ManifestAssociatedFunction({
            executionSelector: this.createAutomation.selector,
            associatedFunction: ManifestFunction({
                functionType: ManifestAssociatedFunctionType.DEPENDENCY,
                functionId: 0, // This must match the MultiOwner plugin's user op validation function identifier.
                dependencyIndex: _MANIFEST_DEPENDENCY_INDEX_OWNER_USER_OP_VALIDATION
            })
        });

        // We do not use runtime validation, so leave these arrays empty.
        manifest.runtimeValidationFunctions = new ManifestAssociatedFunction[](0);
        manifest.preRuntimeValidationHooks = new ManifestAssociatedFunction[](0);

        // Set permissions.
        manifest.permitAnyExternalAddress = true;
        manifest.canSpendNativeToken = true;
        manifest.permittedExecutionSelectors = new bytes4[](0);

        return manifest;
    }

    function pluginMetadata() external pure virtual override returns (PluginMetadata memory) {
        PluginMetadata memory metadata;
        metadata.name = NAME;
        metadata.version = VERSION;
        metadata.author = AUTHOR;
        return metadata;
    }
}
