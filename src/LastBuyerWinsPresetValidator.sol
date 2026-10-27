// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOpenFourPresetValidator} from "./openfour/interfaces/IOpenFourPresetValidator.sol";
import {OpenFourTypes} from "./openfour/libraries/OpenFourTypes.sol";
import {LastBuyerWinsCustomData} from "./LastBuyerWinsCustomData.sol";
import {LastBuyerWinsTradeModule} from "./LastBuyerWinsTradeModule.sol";
import {LastBuyerWinsMigrateModule} from "./LastBuyerWinsMigrateModule.sol";

/// @title LastBuyerWinsPresetValidator
/// @notice Cross-module checks for the Last Buyer Wins preset, run by Core before creation.
contract LastBuyerWinsPresetValidator is IOpenFourPresetValidator {
    uint256 public immutable expectedPresetId;

    constructor(uint256 expectedPresetId_) {
        expectedPresetId = expectedPresetId_;
    }

    function validate(uint256 presetId, OpenFourTypes.TokenInitParams calldata p) external view override {
        if (expectedPresetId != 0) require(presetId == expectedPresetId, "LBWVal: wrong preset");
        require(p.maxSupply > 0 && p.saleAmount > 0 && p.saleAmount <= p.maxSupply, "LBWVal: bad supply");
        require(p.raiseAmount > 0, "LBWVal: zero raise");
        require(p.customDataParams.length > 0, "LBWVal: game params required");

        LastBuyerWinsCustomData.Params memory g = abi.decode(p.customDataParams, (LastBuyerWinsCustomData.Params));
        _validateGame(g);
        require(g.minQualifyingQuote <= p.raiseAmount / 10, "LBWVal: qualifying buy too large");

        LastBuyerWinsTradeModule.TradeConfig memory t = abi.decode(p.tradeParams, (LastBuyerWinsTradeModule.TradeConfig));
        _validateTrade(t);
        if (t.maxBuyAmount != 0) require(t.maxBuyAmount <= p.saleAmount, "LBWVal: maxBuy > sale");
        require(t.postRoundMaxBuy <= p.saleAmount, "LBWVal: postRoundMaxBuy > sale");

        LastBuyerWinsMigrateModule.Params memory m = abi.decode(p.migrateParams, (LastBuyerWinsMigrateModule.Params));
        if (m.migrationAdapter != address(0)) {
            require(m.tokenLiquidityAmount > 0, "LBWVal: zero tokenLiquidity");
            require(m.tokenLiquidityAmount <= p.maxSupply - p.saleAmount, "LBWVal: liquidity > reserve");
            require(m.lpRecipient != address(0), "LBWVal: zero lpRecipient");
        }
    }

    /// @dev Same rules as LastBuyerWinsCustomData._validate (kept in sync by tests).
    function _validateGame(LastBuyerWinsCustomData.Params memory g) internal pure {
        require(g.initialDuration >= 5 minutes, "LBW: initialDuration too short");
        require(g.maxGameDuration <= 30 days, "LBW: game too long");
        require(g.initialDuration <= g.maxGameDuration, "LBW: initial > game");
        require(g.extensionPerBuy > 0 && g.extensionPerBuy <= 1 days, "LBW: bad extension");
        require(g.maxRemaining >= g.initialDuration && g.maxRemaining <= g.maxGameDuration, "LBW: bad maxRemaining");
        require(g.winnerBps >= 5_000 && g.winnerBps <= 10_000, "LBW: bad winnerBps");
    }

    function _validateTrade(LastBuyerWinsTradeModule.TradeConfig memory c) internal pure {
        require(c.buyPotFeeBps <= 1_000 && c.sellPotFeeBps <= 1_000, "LBWTrade: fee too high");
        require(c.buyPotFeeBps > 0 || c.sellPotFeeBps > 0, "LBWTrade: no pot fee");
        require(c.postRoundMaxBuy > 0, "LBWTrade: zero postRoundMaxBuy");
    }
}
