// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IOpenFourTradeModule} from "./openfour/interfaces/IOpenFourTradeModule.sol";
import {IOpenFourModuleSchema} from "./openfour/interfaces/IOpenFourModuleSchema.sol";
import {IOpenFourToken} from "./openfour/interfaces/IOpenFourToken.sol";
import {OpenFourTypes, ParamDescriptor, ModuleEncodeSchema} from "./openfour/libraries/OpenFourTypes.sol";

interface ILastBuyerWinsData {
    function deadline() external view returns (uint256);
    function roundEnded() external view returns (bool);
}

/// @title LastBuyerWinsTradeModule
/// @notice View-only trade policy: routes a pot fee to the token's LastBuyerWins custom-data module.
/// @dev - Buy and sell both pay `potFeeBps` (separately configurable) into the pot.
///      - After the clock hits zero, buys stay allowed (capped by `postRoundMaxBuy`) only so that the
///        next buy can trigger Core's post-buy migration check; they never count for the prize.
///      - No state is written here; all game state lives in the custom-data module.
contract LastBuyerWinsTradeModule is Initializable, IOpenFourTradeModule, IOpenFourModuleSchema {
    uint16 public constant MAX_POT_FEE_BPS = 1_000; // 10% hard ceiling

    /// @param buyPotFeeBps Pot fee on buys, in bps of curve quote.
    /// @param sellPotFeeBps Pot fee on sells, in bps of curve quote.
    /// @param maxBuyAmount Per-trade buy cap in token units during the live round. 0 = unlimited.
    /// @param postRoundMaxBuy Per-trade buy cap in token units after the clock hit zero. Must be > 0.
    struct TradeConfig {
        uint16 buyPotFeeBps;
        uint16 sellPotFeeBps;
        uint256 maxBuyAmount;
        uint256 postRoundMaxBuy;
    }

    address public boundToken;
    address public fourCore;
    TradeConfig public config;
    bytes private _initParams;
    string private _moduleVersion;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function init(address token, address fourCore_, bytes calldata rawParams, string calldata moduleVersion_)
        external
        override
        initializer
    {
        require(token != address(0) && fourCore_ != address(0), "LBWTrade: zero address");
        TradeConfig memory c = abi.decode(rawParams, (TradeConfig));
        _validate(c);
        boundToken = token;
        fourCore = fourCore_;
        config = c;
        _initParams = rawParams;
        _moduleVersion = moduleVersion_;
    }

    function descriptor() external view override returns (bytes8 tagId, string memory tag, string memory version) {
        tag = "module.trade.last_buyer_wins";
        return (bytes8(keccak256(bytes(tag))), tag, _moduleVersion);
    }

    function evaluate(OpenFourTypes.TradeContext calldata ctx)
        external
        view
        override
        returns (OpenFourTypes.TradeResult memory)
    {
        require(fourCore != address(0), "LBWTrade: not initialized");
        require(ctx.token == boundToken, "LBWTrade: wrong token");

        address pot = IOpenFourToken(ctx.token).customData();
        if (pot == address(0)) return _blocked("Missing LastBuyerWins data module");

        if (ctx.isBuy) {
            uint256 maxAmount;
            if (ctx.timestamp >= ILastBuyerWinsData(pot).deadline()) {
                maxAmount = config.postRoundMaxBuy;
            } else {
                maxAmount = config.maxBuyAmount == 0 ? type(uint256).max : config.maxBuyAmount;
            }
            return _allowed(maxAmount, config.buyPotFeeBps, pot);
        }
        return _allowed(type(uint256).max, config.sellPotFeeBps, pot);
    }

    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        ParamDescriptor[] memory p = new ParamDescriptor[](4);
        p[0] = ParamDescriptor("buyPotFeeBps", "uint16", 0, false, "Pot fee on buys (bps)", "100", "Goes to the prize pot. Max 1000.", "0", "1000");
        p[1] = ParamDescriptor("sellPotFeeBps", "uint16", 0, false, "Pot fee on sells (bps)", "200", "Goes to the prize pot. Max 1000.", "0", "1000");
        p[2] = ParamDescriptor("maxBuyAmount", "uint256", 18, true, "Max buy per trade (tokens)", "0", "0 = unlimited during the live round.", "0", "");
        p[3] = ParamDescriptor("postRoundMaxBuy", "uint256", 18, false, "Max buy after clock ends (tokens)", "1", "Small buy that triggers graduation. Does not win.", "1", "");
        return ModuleEncodeSchema("trade", 1, p);
    }

    function getInitParams() external view returns (bytes memory) {
        return _initParams;
    }

    function validateConfig(TradeConfig calldata c) external pure {
        _validate(c);
    }

    function _validate(TradeConfig memory c) internal pure {
        require(c.buyPotFeeBps <= MAX_POT_FEE_BPS && c.sellPotFeeBps <= MAX_POT_FEE_BPS, "LBWTrade: fee too high");
        require(c.buyPotFeeBps > 0 || c.sellPotFeeBps > 0, "LBWTrade: no pot fee");
        require(c.postRoundMaxBuy > 0, "LBWTrade: zero postRoundMaxBuy");
    }

    function _allowed(uint256 maxAmount, uint16 feeBps, address pot) internal pure returns (OpenFourTypes.TradeResult memory) {
        OpenFourTypes.FeeTier[] memory fees;
        if (feeBps > 0) {
            fees = new OpenFourTypes.FeeTier[](1);
            fees[0] = OpenFourTypes.FeeTier({recipient: pot, bps: feeBps});
        } else {
            fees = new OpenFourTypes.FeeTier[](0);
        }
        return OpenFourTypes.TradeResult({allowed: true, minAmount: 0, maxAmount: maxAmount, fees: fees, reason: ""});
    }

    function _blocked(string memory reason) internal pure returns (OpenFourTypes.TradeResult memory) {
        return OpenFourTypes.TradeResult({
            allowed: false,
            minAmount: 0,
            maxAmount: 0,
            fees: new OpenFourTypes.FeeTier[](0),
            reason: reason
        });
    }
}
