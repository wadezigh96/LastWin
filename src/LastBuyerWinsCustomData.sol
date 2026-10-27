// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IOpenFourCustomDataModule} from "./openfour/interfaces/IOpenFourCustomDataModule.sol";
import {IOpenFourModuleSchema} from "./openfour/interfaces/IOpenFourModuleSchema.sol";
import {IOpenFourCore} from "./openfour/interfaces/IOpenFourCore.sol";
import {IWrappedNative} from "./openfour/interfaces/IWrappedNative.sol";
import {OpenFourTypes, ParamDescriptor, ModuleEncodeSchema} from "./openfour/libraries/OpenFourTypes.sol";

/// @title LastBuyerWinsCustomData
/// @notice Countdown + prize-pot state for the "Last Buyer Wins" OpenFour preset.
/// @dev Mechanic:
///      - A countdown starts when the token is created (`initialDuration`).
///      - Every qualifying buy (curve quote >= `minQualifyingQuote`) makes the buyer the
///        current "last buyer" and pushes the deadline forward by `extensionPerBuy`,
///        but never more than `maxRemaining` seconds from now and never past `hardDeadline`.
///      - A pot fee (returned by `LastBuyerWinsTradeModule` as a FeeTier whose recipient is
///        this contract) accumulates here, in native or in the quote ERC20.
///      - The round ends when the deadline passes or when Core migrates the token (sell-out).
///        After that anyone may call `settle()`, which pays `winnerBps` of the pot to the last
///        buyer and the rest to the token creator. `settle()` can be called again to sweep
///        fees that arrive after the round ended (e.g. the trade that triggers migration).
///      The trade module reads `deadline()` / `roundEnded()`; the migrate module reads `deadline()`.
contract LastBuyerWinsCustomData is Initializable, IOpenFourCustomDataModule, IOpenFourModuleSchema {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BPS = 10_000;
    uint256 public constant MIN_INITIAL_DURATION = 5 minutes;
    uint256 public constant MAX_GAME_DURATION = 30 days;

    /// @notice ABI params supplied at token creation (`customDataParams`).
    /// @param initialDuration Seconds on the clock at creation.
    /// @param extensionPerBuy Seconds each qualifying buy adds.
    /// @param maxRemaining Upper bound for (deadline - now) after an extension.
    /// @param maxGameDuration Absolute game length cap from creation; the clock can never pass it.
    /// @param minQualifyingQuote Minimum curve quote (quote-asset wei) for a buy to count.
    /// @param winnerBps Share of the pot paid to the last buyer; the remainder goes to the creator.
    struct Params {
        uint256 initialDuration;
        uint256 extensionPerBuy;
        uint256 maxRemaining;
        uint256 maxGameDuration;
        uint256 minQualifyingQuote;
        uint16 winnerBps;
    }

    address public token;
    address public fourCore;
    Params public params;

    uint256 public startTime;
    uint256 public hardDeadline;
    uint256 private _deadline;
    address public lastBuyer;
    uint256 public lastQualifyingBuyAt;
    uint256 public qualifyingBuys;

    bool public migrated;
    uint256 public migratedAt;

    /// @notice Cumulative amounts paid out (native counted together with wrapped native).
    uint256 public totalPaidToWinner;
    uint256 public totalPaidToCreator;

    bytes private _initParams;
    string private _moduleVersion;
    uint256 private _lock;

    event LastBuyerUpdated(address indexed buyer, uint256 curveQuote, uint256 newDeadline, uint256 qualifyingBuys);
    event RoundClosedByMigration(uint256 timestamp, address indexed winner);
    event PotSettled(address indexed asset, address indexed winner, uint256 winnerAmount, address indexed creator, uint256 creatorAmount);

    modifier onlyFourCore() {
        require(msg.sender == fourCore, "LBW: only fourCore");
        _;
    }

    modifier nonReentrant() {
        require(_lock == 0, "LBW: reentrant");
        _lock = 1;
        _;
        _lock = 0;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function init(address token_, address fourCore_, bytes calldata rawParams, string calldata moduleVersion_)
        external
        override
        initializer
    {
        require(token_ != address(0) && fourCore_ != address(0), "LBW: zero address");
        Params memory p = abi.decode(rawParams, (Params));
        _validate(p);

        token = token_;
        fourCore = fourCore_;
        params = p;
        startTime = block.timestamp;
        hardDeadline = block.timestamp + p.maxGameDuration;
        _deadline = block.timestamp + p.initialDuration;
        _initParams = rawParams;
        _moduleVersion = moduleVersion_;
    }

    /// @notice Accepts native pot fees. Kept minimal so fee pushes never run out of gas.
    receive() external payable {}

    function descriptor() external view override returns (bytes8 tagId, string memory tag, string memory version) {
        tag = "module.data.last_buyer_wins";
        return (bytes8(keccak256(bytes(tag))), tag, _moduleVersion);
    }

    // ------------------------------------------------------------------
    // Core hooks
    // ------------------------------------------------------------------

    /// @notice Records a qualifying buy. Never reverts on business rules (records facts only).
    function afterHook(OpenFourTypes.TradeHookContext calldata ctx) external override onlyFourCore {
        require(ctx.token == token, "LBW: wrong token");
        if (!ctx.isBuy || ctx.executedAmount == 0 || migrated) return;
        if (ctx.timestamp >= _deadline) return; // clock already hit zero: buy does not count
        if (ctx.curveQuote < params.minQualifyingQuote) return;

        uint256 extended = _deadline + params.extensionPerBuy;
        uint256 cap = ctx.timestamp + params.maxRemaining;
        if (extended > cap) extended = cap;
        if (extended > hardDeadline) extended = hardDeadline;
        if (extended > _deadline) _deadline = extended;

        lastBuyer = ctx.trader;
        lastQualifyingBuyAt = ctx.timestamp;
        unchecked {
            qualifyingBuys++;
        }
        emit LastBuyerUpdated(ctx.trader, ctx.curveQuote, _deadline, qualifyingBuys);
    }

    /// @notice Sell-out migration closes the round immediately; the current last buyer wins.
    function onMigrate(OpenFourTypes.MigrateHookContext calldata ctx) external override onlyFourCore {
        require(ctx.token == token, "LBW: wrong token");
        if (migrated) return;
        migrated = true;
        migratedAt = ctx.timestamp;
        if (ctx.timestamp < _deadline) _deadline = ctx.timestamp;
        emit RoundClosedByMigration(ctx.timestamp, lastBuyer);
    }

    // ------------------------------------------------------------------
    // Views used by other modules / UIs
    // ------------------------------------------------------------------

    function deadline() external view returns (uint256) {
        return _deadline;
    }

    function roundEnded() public view returns (bool) {
        return migrated || block.timestamp >= _deadline;
    }

    function timeLeft() external view returns (uint256) {
        if (roundEnded()) return 0;
        return _deadline - block.timestamp;
    }

    /// @notice Current pot: native balance plus quote-ERC20 balance (wrapped native for native quotes).
    function potBalance() external view returns (uint256 nativeAmount, address erc20, uint256 erc20Amount) {
        nativeAmount = address(this).balance;
        erc20 = _potErc20();
        if (erc20 != address(0)) erc20Amount = IERC20(erc20).balanceOf(address(this));
    }

    /// @notice Who receives the winner share if the round were settled now.
    function currentWinner() public view returns (address) {
        return lastBuyer != address(0) ? lastBuyer : _creator();
    }

    /// @notice One-call snapshot for frontends and bots.
    struct GameState {
        uint256 deadline;
        uint256 hardDeadline;
        uint256 timeLeft;
        bool ended;
        bool migrated;
        address lastBuyer;
        uint256 qualifyingBuys;
        uint256 minQualifyingQuote;
        uint256 extensionPerBuy;
        uint16 winnerBps;
        uint256 potNative;
        address potErc20;
        uint256 potErc20Amount;
    }

    function gameState() external view returns (GameState memory s) {
        s.deadline = _deadline;
        s.hardDeadline = hardDeadline;
        s.ended = roundEnded();
        s.timeLeft = s.ended ? 0 : _deadline - block.timestamp;
        s.migrated = migrated;
        s.lastBuyer = lastBuyer;
        s.qualifyingBuys = qualifyingBuys;
        s.minQualifyingQuote = params.minQualifyingQuote;
        s.extensionPerBuy = params.extensionPerBuy;
        s.winnerBps = params.winnerBps;
        s.potNative = address(this).balance;
        s.potErc20 = _potErc20();
        if (s.potErc20 != address(0)) s.potErc20Amount = IERC20(s.potErc20).balanceOf(address(this));
    }

    // ------------------------------------------------------------------
    // Settlement (permissionless, pull-style, callable repeatedly to sweep)
    // ------------------------------------------------------------------

    function settle() external nonReentrant {
        require(roundEnded(), "LBW: round live");
        address creator = _creator();
        require(creator != address(0), "LBW: creator unknown");
        address winner = lastBuyer != address(0) ? lastBuyer : creator;

        address erc20 = _potErc20();
        address wnative = _wrappedNative();

        // Effects before interactions: read balances, then pay.
        uint256 nativeBal = address(this).balance;
        if (nativeBal > 0) {
            (uint256 w, uint256 c) = _split(nativeBal);
            totalPaidToWinner += w;
            totalPaidToCreator += c;
            _payNative(winner, w, wnative);
            _payNative(creator, c, wnative);
            emit PotSettled(address(0), winner, w, creator, c);
        }

        if (erc20 != address(0)) {
            uint256 bal = IERC20(erc20).balanceOf(address(this));
            if (bal > 0) {
                (uint256 w, uint256 c) = _split(bal);
                totalPaidToWinner += w;
                totalPaidToCreator += c;
                if (w > 0) IERC20(erc20).safeTransfer(winner, w);
                if (c > 0) IERC20(erc20).safeTransfer(creator, c);
                emit PotSettled(erc20, winner, w, creator, c);
            }
        }
    }

    // ------------------------------------------------------------------
    // Schema / params
    // ------------------------------------------------------------------

    function moduleEncodeSchema() external pure override returns (ModuleEncodeSchema memory) {
        ParamDescriptor[] memory p = new ParamDescriptor[](6);
        p[0] = _desc("initialDuration", "uint256", 0, "Starting clock (seconds)", "3600", "Time on the countdown at launch.", "300", "2592000");
        p[1] = _desc("extensionPerBuy", "uint256", 0, "Seconds added per qualifying buy", "60", "Each qualifying buy pushes the deadline by this much.", "1", "86400");
        p[2] = _desc("maxRemaining", "uint256", 0, "Max clock after extension (seconds)", "3600", "The clock can never show more than this. Must be >= starting clock.", "300", "2592000");
        p[3] = _desc("maxGameDuration", "uint256", 0, "Hard game length cap (seconds)", "604800", "Absolute end from creation, regardless of buys.", "300", "2592000");
        p[4] = _desc("minQualifyingQuote", "uint256", 18, "Min buy to count (quote asset)", "0.01", "Smaller buys trade normally but do not reset the winner.", "0", "");
        p[5] = _desc("winnerBps", "uint16", 0, "Winner share of pot (bps)", "10000", "Remainder goes to the token creator. 5000-10000.", "5000", "10000");
        return ModuleEncodeSchema("customData", 1, p);
    }

    function getInitParams() external view returns (bytes memory) {
        return _initParams;
    }

    /// @notice Exposed so the preset validator applies the exact same rules as `init`.
    function validateParams(Params calldata p) external pure {
        _validate(p);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _validate(Params memory p) internal pure {
        require(p.initialDuration >= MIN_INITIAL_DURATION, "LBW: initialDuration too short");
        require(p.maxGameDuration <= MAX_GAME_DURATION, "LBW: game too long");
        require(p.initialDuration <= p.maxGameDuration, "LBW: initial > game");
        require(p.extensionPerBuy > 0 && p.extensionPerBuy <= 1 days, "LBW: bad extension");
        require(p.maxRemaining >= p.initialDuration && p.maxRemaining <= p.maxGameDuration, "LBW: bad maxRemaining");
        require(p.winnerBps >= 5_000 && p.winnerBps <= MAX_BPS, "LBW: bad winnerBps");
    }

    function _split(uint256 amount) internal view returns (uint256 w, uint256 c) {
        w = (amount * params.winnerBps) / MAX_BPS;
        c = amount - w;
    }

    function _payNative(address to, uint256 amount, address wnative) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount, gas: 50_000}("");
        if (ok) return;
        // Recipient cannot take native (e.g. a contract without receive): pay wrapped native instead,
        // so a hostile winner can never brick settlement for the creator.
        require(wnative != address(0), "LBW: native send failed");
        IWrappedNative(wnative).deposit{value: amount}();
        IERC20(wnative).safeTransfer(to, amount);
    }

    function _creator() internal view returns (address creator) {
        (, creator,,,,,,,,,,,,,,,,,,) = IOpenFourCore(fourCore).tokens(token);
    }

    function _quoteAsset() internal view returns (address quote) {
        (,,,,,,,,, quote,,,,,,,,,,) = IOpenFourCore(fourCore).tokens(token);
    }

    function _wrappedNative() internal view returns (address w) {
        try IOpenFourCore(fourCore).wrappedNative() returns (address a) {
            w = a;
        } catch {}
    }

    /// @dev ERC20 balance to sweep: the quote token, or wrapped native for native-quoted tokens.
    function _potErc20() internal view returns (address) {
        address quote = _quoteAsset();
        if (quote != address(0)) return quote;
        return _wrappedNative();
    }

    function _desc(
        string memory name,
        string memory abiType,
        uint8 decimals,
        string memory title,
        string memory def,
        string memory hint,
        string memory minV,
        string memory maxV
    ) internal pure returns (ParamDescriptor memory) {
        return ParamDescriptor({
            name: name,
            abiType: abiType,
            decimals: decimals,
            optional: false,
            title: title,
            defaultValue: def,
            hint: hint,
            minValue: minV,
            maxValue: maxV
        });
    }
}
