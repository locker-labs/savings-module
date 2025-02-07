// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {BasePlugin} from "modular-account-libs/plugins/BasePlugin.sol";
import {IPluginExecutor} from "modular-account-libs/interfaces/IPluginExecutor.sol";
import {IStandardExecutor} from "modular-account-libs/interfaces/IStandardExecutor.sol";
import {ManifestFunction, ManifestExecutionHook, ManifestAssociatedFunctionType, ManifestAssociatedFunction, PluginManifest, PluginMetadata, IPlugin} from "modular-account-libs/interfaces/IPlugin.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

enum FunctionId {
    EXECUTE_FUNCTION,
    EXECUTE_BATCH_FUNCTION
}

/// @title Savings Plugin
/// @author Locker
/// @notice This plugin lets users automatically save when making payments
contract SavingsPlugin is BasePlugin {
    // metadata used by the pluginMetadata() method down below
    string public constant NAME = "Locker Savings Plugin";
    string public constant VERSION = "0.0.1";
    string public constant AUTHOR = "Marvin Arnold";

    // this is a constant used in the manifest, to reference our only dependency: the single owner plugin
    // since it is the first, and only, plugin the index 0 will reference the single owner plugin
    // we can use this to tell the modular account that we should use the single owner plugin to validate our user op
    // in other words, we'll say "make sure the person calling createAutomation is an owner of the account using our single plugin"
    uint256
        internal constant _MANIFEST_DEPENDENCY_INDEX_OWNER_USER_OP_VALIDATION =
        0;

    struct SavingsAutomation {
        address savingsAccount; // where to send the funds
        uint256 roundUpTo; // <- for a USD stable 1,000,000 would be 1 USD (6 decimals)
        bool enabled;
    }

    // Every owner address can have multiple automated savings configured.
    mapping(address => mapping(uint256 => SavingsAutomation))
        public savingsAutomations;

    // ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
    // ┃    Execution functions    ┃
    // ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

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

    // ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
    // ┃    Plugin interface functions    ┃
    // ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

    /// @inheritdoc BasePlugin
    function onInstall(bytes calldata) external pure override {}

    /// @inheritdoc BasePlugin
    function onUninstall(bytes calldata) external pure override {}

    function preExecutionHook(
        uint8 functionId,
        address,
        uint256 value,
        bytes calldata data
    ) external override returns (bytes memory) {
        // Retrieve the automation rule for the sender
        SavingsAutomation memory automation = savingsAutomations[msg.sender][0];
        if (automation.enabled && automation.roundUpTo > 0) {
            uint256 roundUpTo = automation.roundUpTo;

            // First decode the outer structure of `callData`
            (
                address tokenAddress,
                uint256 ethValue,
                bytes memory innerData
            ) = abi.decode(
                    data[4:], // Skip the first 4 bytes (selector for `execute`)
                    (address, uint256, bytes)
                );

            // Separate the selector and payload of `innerData`
            bytes4 transferSelector;
            address recipient;
            uint256 transferAmount;

            // Decode innerData to extract selector, recipient, and transfer amount
            assembly {
                transferSelector := mload(add(innerData, 32)) // First 4 bytes (selector)
                recipient := mload(add(innerData, 36)) // Next 32 bytes (address)
                transferAmount := mload(add(innerData, 68)) // Next 32 bytes (uint256)
            }

            uint256 roundUpAmount = ((transferAmount + roundUpTo - 1) /
                roundUpTo) * roundUpTo;
            uint256 savingsAmount = roundUpAmount - transferAmount;

            if (savingsAmount > 0) {
                // Perform the savings transfer before the main transfer
                IPluginExecutor(msg.sender).executeFromPluginExternal(
                    tokenAddress,
                    0, // No ETH required
                    abi.encodeWithSelector(
                        IERC20.transfer.selector,
                        automation.savingsAccount,
                        savingsAmount
                    )
                );
            }
        }

        // Return an empty bytes array as no additional context is needed for post-execution
        return "";
    }

    /// @inheritdoc BasePlugin
    function pluginManifest()
        external
        pure
        override
        returns (PluginManifest memory)
    {
        PluginManifest memory manifest;

        // since we are using the modular account, we will specify one depedency
        // which will handle the user op validation for ownership
        // you can find this depedency specified in the installPlugin call in the tests
        manifest.dependencyInterfaceIds = new bytes4[](1);
        manifest.dependencyInterfaceIds[0] = type(IPlugin).interfaceId;

        manifest.executionFunctions = new bytes4[](1);
        manifest.executionFunctions[0] = this.createAutomation.selector;

        // you can think of ManifestFunction as a reference to a function somewhere,
        // we want to say "use this function" for some purpose - in this case,
        // we'll be using the user op validation function from the single owner dependency
        // and this is specified by the depdendency index
        ManifestFunction
            memory ownerUserOpValidationFunction = ManifestFunction({
                functionType: ManifestAssociatedFunctionType.DEPENDENCY,
                functionId: 0, // unused since it's a dependency
                dependencyIndex: _MANIFEST_DEPENDENCY_INDEX_OWNER_USER_OP_VALIDATION
            });

        // here we will link together the createAutomation function with the single owner user op validation
        // this basically says "use this user op validation function and make sure everythings okay before calling createAutomation"
        // this will ensure that only an owner of the account can call createAutomation
        manifest.userOpValidationFunctions = new ManifestAssociatedFunction[](
            1
        );
        manifest.userOpValidationFunctions[0] = ManifestAssociatedFunction({
            executionSelector: this.createAutomation.selector,
            associatedFunction: ownerUserOpValidationFunction
        });

        // finally here we will always deny runtime calls to the createAutomation function as we will only call it through user ops
        // this avoids a potential issue where a future plugin may define
        // a runtime validation function for it and unauthorized calls may occur due to that
        manifest.preRuntimeValidationHooks = new ManifestAssociatedFunction[](
            1
        );
        manifest.preRuntimeValidationHooks[0] = ManifestAssociatedFunction({
            executionSelector: this.createAutomation.selector,
            associatedFunction: ManifestFunction({
                functionType: ManifestAssociatedFunctionType
                    .PRE_HOOK_ALWAYS_DENY,
                functionId: 0,
                dependencyIndex: 0
            })
        });

        // Register post-execution hooks on ERC20 transfers
        manifest.executionHooks = new ManifestExecutionHook[](1);

        ManifestFunction memory none = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.NONE,
            functionId: 0,
            dependencyIndex: 0
        });

        ManifestFunction memory execHook = ManifestFunction({
            functionType: ManifestAssociatedFunctionType.SELF,
            functionId: uint8(FunctionId.EXECUTE_FUNCTION),
            dependencyIndex: 0
        });

        manifest.executionHooks[0] = ManifestExecutionHook({
            executionSelector: IStandardExecutor.execute.selector,
            preExecHook: execHook,
            postExecHook: none
        });

        manifest.permitAnyExternalAddress = true;
        manifest.canSpendNativeToken = true;

        return manifest;
    }

    /// @inheritdoc BasePlugin
    function pluginMetadata()
        external
        pure
        virtual
        override
        returns (PluginMetadata memory)
    {
        PluginMetadata memory metadata;
        metadata.name = NAME;
        metadata.version = VERSION;
        metadata.author = AUTHOR;
        return metadata;
    }
}
