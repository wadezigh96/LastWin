// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {OpenFourTypes} from "../src/openfour/libraries/OpenFourTypes.sol";
import {IOpenFourRegistry} from "../src/openfour/interfaces/IOpenFourRegistry.sol";
import {LastBuyerWinsCustomData} from "../src/LastBuyerWinsCustomData.sol";
import {LastBuyerWinsTradeModule} from "../src/LastBuyerWinsTradeModule.sol";
import {LastBuyerWinsMigrateModule} from "../src/LastBuyerWinsMigrateModule.sol";
import {LastBuyerWinsPresetValidator} from "../src/LastBuyerWinsPresetValidator.sol";

/// @notice Minimal write surface of OpenFourRegistry (fork only).
/// @dev The minimal IOpenFourRegistry interface shipped in src/openfour/ is
///      read-only; the live Registry implementation also exposes these
///      owner-only upserts (see openfour-docs developer/workbench/src/eth/moduleRegistry.js).
interface IForkRegistry {
    function owner() external view returns (address);
    function upsertModule(
        bytes32 moduleKey,
        address implementation,
        uint8 kind,
        OpenFourTypes.ModuleMetadata calldata metadata,
        bool active
    ) external;
    function upsertPreset(OpenFourTypes.Preset calldata preset) external;
    function getPreset(uint256 presetId) external view returns (OpenFourTypes.Preset memory);
    function getModule(bytes32 moduleKey) external view returns (IOpenFourRegistry.ModuleRecord memory);
    function getPresetIds() external view returns (uint256[] memory);
}

/// @notice Registers Last Buyer Wins as a preset on a DEVELOPER-OWNED FORK Registry.
/// @dev FORK ONLY. Never point this at the official Registry (BSC testnet
///      0xE5014c0616e528B0ABF7CC120A58032c1FbE7060) or any mainnet Registry:
///      official registration is done by OpenFour governance after audit.
///      The caller must be Registry.owner() (the fork-deploy deployer).
///
///      Usage (BSC testnet fork, after `npm run fork` in openfour-docs/developer/fork-deploy):
///        FORK_REGISTRY=0x... PRESET_ID=1778027615734 \
///          forge script script/RegisterForkPreset.s.sol \
///          --rpc-url $BSC_TESTNET_RPC --private-key $PK --broadcast
///
///      Env (all optional except FORK_REGISTRY):
///        PRESET_ID      preset id, must not collide with getPresetIds() (default 1778027615734;
///                       fork presets are ...722 bondingV1, ...723 bondingTaxV1, ...733 stock4TaxV1)
///        DATA_IMPL      reuse a deployed LastBuyerWinsCustomData (default: deploy fresh)
///        TRADE_IMPL     reuse a deployed LastBuyerWinsTradeModule (default: deploy fresh)
///        MIGRATE_IMPL   reuse a deployed LastBuyerWinsMigrateModule (default: deploy fresh)
///        VALIDATOR      reuse a deployed LastBuyerWinsPresetValidator (default: deploy fresh,
///                       constructed with PRESET_ID so it only accepts this preset)
///        BONDING_PRESET preset to copy token/vault/curve/tokenImpl slots from (default 1778027615722)
contract RegisterForkPreset is Script {
    bytes32 public constant DATA_KEY = keccak256("module.data.last_buyer_wins");
    bytes32 public constant TRADE_KEY = keccak256("module.trade.last_buyer_wins");
    bytes32 public constant MIGRATE_KEY = keccak256("module.migrate.last_buyer_wins");

    // Registry ModuleKind: 0 Token, 1 Vault, 2 Curve, 3 Trade, 4 Migrate, 5 CustomData.
    uint8 private constant KIND_TRADE = 3;
    uint8 private constant KIND_MIGRATE = 4;
    uint8 private constant KIND_CUSTOM_DATA = 5;

    function run() external {
        address registryAddr = vm.envAddress("FORK_REGISTRY");
        uint256 presetId = vm.envOr("PRESET_ID", uint256(1_778_027_615_734));
        uint256 bondingPresetId = vm.envOr("BONDING_PRESET", uint256(1_778_027_615_722));
        IForkRegistry registry = IForkRegistry(registryAddr);

        require(block.chainid != 56 && block.chainid != 4663, "LBW: never register on mainnet");
        require(registry.owner() == msg.sender, "LBW: caller is not fork Registry owner");

        // Reuse the fork bonding preset's untouched slots (token, vault, curve, token impl).
        OpenFourTypes.Preset memory bonding = registry.getPreset(bondingPresetId);
        require(bonding.active, "LBW: bonding preset not found on this fork");

        vm.startBroadcast();
        address dataImpl = vm.envOr("DATA_IMPL", address(0));
        if (dataImpl == address(0)) dataImpl = address(new LastBuyerWinsCustomData());
        address tradeImpl = vm.envOr("TRADE_IMPL", address(0));
        if (tradeImpl == address(0)) tradeImpl = address(new LastBuyerWinsTradeModule());
        address migrateImpl = vm.envOr("MIGRATE_IMPL", address(0));
        if (migrateImpl == address(0)) migrateImpl = address(new LastBuyerWinsMigrateModule());
        address validator = vm.envOr("VALIDATOR", address(0));
        if (validator == address(0)) validator = address(new LastBuyerWinsPresetValidator(presetId));

        registry.upsertModule(
            DATA_KEY,
            dataImpl,
            KIND_CUSTOM_DATA,
            OpenFourTypes.ModuleMetadata({
                moduleId: DATA_KEY,
                version: "1.0.0",
                name: "LastBuyerWinsCustomData",
                description: "Countdown + prize-pot state for Last Buyer Wins",
                author: msg.sender,
                feeShareBps: 0
            }),
            true
        );
        registry.upsertModule(
            TRADE_KEY,
            tradeImpl,
            KIND_TRADE,
            OpenFourTypes.ModuleMetadata({
                moduleId: TRADE_KEY,
                version: "1.0.0",
                name: "LastBuyerWinsTradeModule",
                description: "View-only trade policy routing a pot fee to the Last Buyer Wins pot",
                author: msg.sender,
                feeShareBps: 0
            }),
            true
        );
        registry.upsertModule(
            MIGRATE_KEY,
            migrateImpl,
            KIND_MIGRATE,
            OpenFourTypes.ModuleMetadata({
                moduleId: MIGRATE_KEY,
                version: "1.0.0",
                name: "LastBuyerWinsMigrateModule",
                description: "Graduates the token on sell-out or when the countdown hits zero",
                author: msg.sender,
                feeShareBps: 0
            }),
            true
        );

        registry.upsertPreset(
            OpenFourTypes.Preset({
                id: presetId,
                name: "LastBuyerWins",
                description: "Last Buyer Wins: countdown launch, every qualifying buy takes the lead and adds time; last buyer takes the pot at zero or sell-out",
                version: "1.0.0",
                active: true,
                createEnabled: true,
                validator: validator,
                tokenModuleId: bonding.tokenModuleId,
                vaultModuleId: bonding.vaultModuleId,
                curveModuleId: bonding.curveModuleId,
                tradeModuleId: TRADE_KEY,
                migrateModuleId: MIGRATE_KEY,
                tokenImplId: bonding.tokenImplId,
                customDataId: DATA_KEY,
                author: msg.sender
            })
        );
        vm.stopBroadcast();

        // On-chain read-back: fail loudly if registration did not stick.
        // NOTE: getModule returns a single ModuleRecord struct; decoding it as
        // four flat values fails (struct encoding starts with an offset word).
        IOpenFourRegistry.ModuleRecord memory dataMod = registry.getModule(DATA_KEY);
        IOpenFourRegistry.ModuleRecord memory tradeMod = registry.getModule(TRADE_KEY);
        IOpenFourRegistry.ModuleRecord memory migrateMod = registry.getModule(MIGRATE_KEY);
        require(dataMod.active && tradeMod.active && migrateMod.active, "LBW: module not active after upsert");
        require(dataMod.beacon != address(0) && tradeMod.beacon != address(0) && migrateMod.beacon != address(0), "LBW: module beacon missing");
        OpenFourTypes.Preset memory created = registry.getPreset(presetId);
        require(created.active && created.createEnabled, "LBW: preset not active after upsert");

        console2.log("Fork Registry      ", registryAddr);
        console2.log("Preset ID          ", presetId);
        console2.log("CustomData impl    ", dataImpl);
        console2.log("Trade impl         ", tradeImpl);
        console2.log("Migrate impl       ", migrateImpl);
        console2.log("Validator          ", validator);
        console2.log("CustomData beacon  ", dataMod.beacon);
        console2.log("Trade beacon       ", tradeMod.beacon);
        console2.log("Migrate beacon     ", migrateMod.beacon);
    }
}
