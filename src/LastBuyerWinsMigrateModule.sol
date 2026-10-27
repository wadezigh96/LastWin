// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IOpenFourMigrateModule} from "./openfour/interfaces/IOpenFourMigrateModule.sol";
import {IOpenFourModuleSchema} from "./openfour/interfaces/IOpenFourModuleSchema.sol";
import {IOpenFourToken} from "./openfour/interfaces/IOpenFourToken.sol";
import {IOpenFourVault} from "./openfour/interfaces/IOpenFourVault.sol";
import {IPancakeV2MigrationAdapter} from "./openfour/interfaces/IPancakeV2MigrationAdapter.sol";
import {OpenFourTypes, ParamDescriptor, ModuleEncodeSchema} from "./openfour/libraries/OpenFourTypes.sol";

interface ILastBuyerWinsDeadline {
    function deadline() external view returns (uint256);
}

/// @title LastBuyerWinsMigrateModule
/// @notice Graduates the token when the curve sells out OR the countdown hits zero.
/// @dev Liquidity actions are delegated to a PancakeSwap V2 adapter, mirroring the official sample.
///      Conditions are rechecked in `executeMigration`; `hookData` is only a capped hint.
contract LastBuyerWinsMigrateModule is Initializable, IOpenFourMigrateModule, IOpenFourModuleSchema {
    uint8 private constant PCS_V2_ENCODED_MIGRATED_DATA_V1 = 1;

    /// @param migrationAdapter PCS V2 adapter; 0x0 skips on-chain liquidity actions.
    /// @param lpRecipient Recipient of LP tokens (use 0xdead to burn LP).
    /// @param tokenLiquidityAmount Token amount paired into liquidity.
    /// @param maxQuoteToUse Cap on quote moved into liquidity. 0 = all raised.
    struct Params {
        address migrationAdapter;
        address lpRecipient;
        uint256 tokenLiquidityAmount;
        uint256 maxQuoteToUse;
    }

    address public boundToken;
    address public fourCore;
    Params public params;
    bytes private _initParams;
    string private _moduleVersion;

    modifier onlyFourCore() {
        require(msg.sender == fourCore, "LBWMigrate: only fourCore");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function init(address token, address fourCore_, address, bytes calldata rawParams, string calldata moduleVersion_)
        external
        override
        initializer
    {
        require(token != address(0) && fourCore_ != address(0), "LBWMigrate: zero address");
        Params memory p = abi.decode(rawParams, (Params));
        if (p.migrationAdapter != address(0)) {
            require(p.tokenLiquidityAmount > 0, "LBWMigrate: zero tokenLiquidity");
            require(p.lpRecipient != address(0), "LBWMigrate: zero lpRecipient");
        }
        boundToken = token;
        fourCore = fourCore_;
        params = p;
        _initParams = rawParams;
        _moduleVersion = moduleVersion_;
    }

    function descriptor() external view override returns (bytes8 tagId, string memory tag, string memory version) {
        tag = "module.migrate.last_buyer_wins";
        return (bytes8(keccak256(bytes(tag))), tag, _moduleVersion);
    }

    function evaluate(OpenFourTypes.MigrateContext calldata ctx)
        external
        view
        override
        onlyFourCore
        returns (OpenFourTypes.MigrateResult memory)
    {
        require(ctx.token == boundToken, "LBWMigrate: wrong token");
        if (!_canMigrate(ctx.soldOut, ctx.timestamp)) {
            return OpenFourTypes.MigrateResult({canMigrate: false, data: "", reason: "Clock still running"});
        }
        return OpenFourTypes.MigrateResult({canMigrate: true, data: abi.encode(_cap(ctx.totalRaised)), reason: ""});
    }

    function executeMigration(OpenFourTypes.MigrateHookContext calldata ctx, bytes calldata hookData)
        external
        override
        onlyFourCore
        returns (uint8 migratedDataVersion, bytes memory encodedMigratedData)
    {
        require(ctx.token == boundToken, "LBWMigrate: wrong token");
        bool soldOut = IOpenFourVault(ctx.vault).isSoldOut();
        require(_canMigrate(soldOut, ctx.timestamp), "LBWMigrate: conditions not met");
        if (params.migrationAdapter == address(0)) return (0, "");

        uint256 hinted = hookData.length == 0 ? ctx.totalRaised : abi.decode(hookData, (uint256));
        if (hinted > ctx.totalRaised) hinted = ctx.totalRaised;
        uint256 quoteToUse = _cap(hinted);
        address pair = IPancakeV2MigrationAdapter(params.migrationAdapter).executeLiquidity(
            ctx, quoteToUse, params.tokenLiquidityAmount, params.lpRecipient
        );
        require(pair != address(0), "LBWMigrate: pair missing");
        IOpenFourToken(ctx.token).setMigratedPool(pair, true);
        return (PCS_V2_ENCODED_MIGRATED_DATA_V1, abi.encode(pair));
    }

    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        ParamDescriptor[] memory p = new ParamDescriptor[](4);
        p[0] = ParamDescriptor("migrationAdapter", "address", 0, true, "Migration adapter", "", "PCS V2 adapter. 0x0 skips liquidity.", "", "");
        p[1] = ParamDescriptor("lpRecipient", "address", 0, true, "LP recipient", "0x000000000000000000000000000000000000dEaD", "Default burns LP.", "", "");
        p[2] = ParamDescriptor("tokenLiquidityAmount", "uint256", 18, false, "Token liquidity amount", "0", "", "0", "");
        p[3] = ParamDescriptor("maxQuoteToUse", "uint256", 18, true, "Max quote to use", "0", "0 = all raised.", "0", "");
        return ModuleEncodeSchema("migrate", 1, p);
    }

    function getInitParams() external view returns (bytes memory) {
        return _initParams;
    }

    /// @notice Public predicate for UIs: would migration be allowed right now?
    function canMigrateNow() external view returns (bool) {
        address vault = IOpenFourToken(boundToken).vault();
        return _canMigrate(IOpenFourVault(vault).isSoldOut(), block.timestamp);
    }

    function _canMigrate(bool soldOut, uint256 timestamp) internal view returns (bool) {
        if (soldOut) return true;
        address data = IOpenFourToken(boundToken).customData();
        if (data == address(0)) return false;
        return timestamp >= ILastBuyerWinsDeadline(data).deadline();
    }

    function _cap(uint256 q) internal view returns (uint256) {
        if (params.maxQuoteToUse > 0 && q > params.maxQuoteToUse) return params.maxQuoteToUse;
        return q;
    }
}
