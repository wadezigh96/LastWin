// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {LastBuyerWinsCustomData} from "../src/LastBuyerWinsCustomData.sol";
import {LastBuyerWinsTradeModule} from "../src/LastBuyerWinsTradeModule.sol";
import {LastBuyerWinsMigrateModule} from "../src/LastBuyerWinsMigrateModule.sol";
import {LastBuyerWinsPresetValidator} from "../src/LastBuyerWinsPresetValidator.sol";

/// @notice Deploys the module implementations (clone targets) and the preset validator.
/// @dev Registration of modules/preset in OpenFourRegistry is done by OpenFour governance, not by this script.
///      Usage (BSC testnet):
///        PRESET_ID=0 forge script script/Deploy.s.sol --rpc-url $BSC_TESTNET_RPC --private-key $PK --broadcast
contract Deploy is Script {
    function run() external {
        uint256 presetId = vm.envOr("PRESET_ID", uint256(0));
        vm.startBroadcast();
        LastBuyerWinsCustomData data = new LastBuyerWinsCustomData();
        LastBuyerWinsTradeModule trade = new LastBuyerWinsTradeModule();
        LastBuyerWinsMigrateModule migrate = new LastBuyerWinsMigrateModule();
        LastBuyerWinsPresetValidator validator = new LastBuyerWinsPresetValidator(presetId);
        vm.stopBroadcast();

        console2.log("LastBuyerWinsCustomData impl ", address(data));
        console2.log("LastBuyerWinsTradeModule impl", address(trade));
        console2.log("LastBuyerWinsMigrateModule impl", address(migrate));
        console2.log("LastBuyerWinsPresetValidator ", address(validator));
    }
}
