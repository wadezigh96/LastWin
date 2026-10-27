// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LastBuyerWinsCustomData} from "../src/LastBuyerWinsCustomData.sol";
import {LastBuyerWinsTradeModule} from "../src/LastBuyerWinsTradeModule.sol";
import {LastBuyerWinsMigrateModule} from "../src/LastBuyerWinsMigrateModule.sol";
import {LastBuyerWinsPresetValidator} from "../src/LastBuyerWinsPresetValidator.sol";
import {OpenFourTypes} from "../src/openfour/libraries/OpenFourTypes.sol";

contract MockWBNB is ERC20("Wrapped BNB", "WBNB") {
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 a) external { _burn(msg.sender, a); payable(msg.sender).transfer(a); }
}

contract MockUSD is ERC20("USD", "USD") {
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract MockVault {
    bool public isSoldOut;
    function setSoldOut(bool v) external { isSoldOut = v; }
}

contract MockToken {
    address public customData;
    address public vault;
    mapping(address => bool) public migratedPools;
    constructor(address v) { vault = v; }
    function setCustomData(address d) external { customData = d; }
    function setMigratedPool(address p, bool e) external { migratedPools[p] = e; }
}

contract MockCore {
    address public creator;
    address public quote;
    address public wrappedNative;
    constructor(address c, address q, address w) { creator = c; quote = q; wrappedNative = w; }
    function tokens(address t) external view returns (
        uint32, address, uint256, address, string memory, string memory, uint256, uint256, uint256, address,
        address, address, address, address, address, address, uint256, bool, bool, bool
    ) {
        return (1, creator, 1, t, "", "", 0, 0, 0, quote, address(0), address(0), address(0), address(0), address(0), address(0), 0, true, false, false);
    }
}

contract NativeRejecter {}

contract Reenterer {
    LastBuyerWinsCustomData public d;
    bool public tried;
    bool public reentered;
    function set(LastBuyerWinsCustomData d_) external { d = d_; }
    receive() external payable {
        if (!tried) {
            tried = true;
            try d.settle() { reentered = true; } catch {}
        }
    }
}

contract LastBuyerWinsTest is Test {
    LastBuyerWinsCustomData dataImpl;
    LastBuyerWinsTradeModule tradeImpl;
    LastBuyerWinsMigrateModule migrateImpl;

    MockWBNB wbnb;
    MockVault vault;
    MockToken token;
    MockCore core;
    LastBuyerWinsCustomData data;
    LastBuyerWinsTradeModule trade;
    LastBuyerWinsMigrateModule migrate;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant T0 = 1_800_000_000;

    function _game() internal pure returns (LastBuyerWinsCustomData.Params memory) {
        return LastBuyerWinsCustomData.Params({
            initialDuration: 1 hours,
            extensionPerBuy: 60,
            maxRemaining: 1 hours,
            maxGameDuration: 7 days,
            minQualifyingQuote: 0.01 ether,
            winnerBps: 9_000
        });
    }

    function _deploy(address quote) internal {
        vm.warp(T0);
        dataImpl = new LastBuyerWinsCustomData();
        tradeImpl = new LastBuyerWinsTradeModule();
        migrateImpl = new LastBuyerWinsMigrateModule();
        wbnb = new MockWBNB();
        vault = new MockVault();
        token = new MockToken(address(vault));
        core = new MockCore(creator, quote, address(wbnb));

        data = LastBuyerWinsCustomData(payable(Clones.clone(address(dataImpl))));
        trade = LastBuyerWinsTradeModule(Clones.clone(address(tradeImpl)));
        migrate = LastBuyerWinsMigrateModule(Clones.clone(address(migrateImpl)));
        token.setCustomData(address(data));

        data.init(address(token), address(core), abi.encode(_game()), "1.0.0");
        trade.init(address(token), address(core), abi.encode(LastBuyerWinsTradeModule.TradeConfig(100, 200, 0, 1 ether)), "1.0.0");
        migrate.init(address(token), address(core), address(0), abi.encode(LastBuyerWinsMigrateModule.Params(address(0), address(0), 0, 0)), "1.0.0");
    }

    function setUp() public {
        _deploy(address(0)); // native quote
    }

    function _buy(address who, uint256 quote) internal {
        vm.prank(address(core));
        data.afterHook(OpenFourTypes.TradeHookContext({
            token: address(token), trader: who, requestedAmount: 1 ether, executedAmount: 1 ether, isBuy: true,
            timestamp: block.timestamp, blockNumber: block.number, curveQuote: quote, traderQuote: quote, proof: ""
        }));
    }

    function _sell(address who) internal {
        vm.prank(address(core));
        data.afterHook(OpenFourTypes.TradeHookContext({
            token: address(token), trader: who, requestedAmount: 1 ether, executedAmount: 1 ether, isBuy: false,
            timestamp: block.timestamp, blockNumber: block.number, curveQuote: 1 ether, traderQuote: 1 ether, proof: ""
        }));
    }

    function _tradeCtx(bool isBuy) internal view returns (OpenFourTypes.TradeContext memory) {
        return OpenFourTypes.TradeContext({
            token: address(token), trader: alice, amount: 1 ether, isBuy: isBuy, timestamp: block.timestamp,
            blockNumber: block.number, remainingForSale: 0, totalRaised: 0, curveQuote: 1 ether, proof: ""
        });
    }

    // ---------------- clock ----------------

    function test_initialClock() public view {
        assertEq(data.deadline(), T0 + 1 hours);
        assertEq(data.hardDeadline(), T0 + 7 days);
        assertEq(data.timeLeft(), 1 hours);
        assertFalse(data.roundEnded());
        assertEq(data.currentWinner(), creator);
    }

    function test_buyExtendsButCapsAtMaxRemaining() public {
        _buy(alice, 1 ether);
        // already at 1h remaining, cap = now + 1h
        assertEq(data.deadline(), T0 + 1 hours);
        assertEq(data.lastBuyer(), alice);
        vm.warp(T0 + 30 minutes);
        _buy(bob, 1 ether);
        assertEq(data.deadline(), T0 + 1 hours + 60);
        assertEq(data.lastBuyer(), bob);
        assertEq(data.qualifyingBuys(), 2);
    }

    function test_smallBuyDoesNotCount() public {
        vm.warp(T0 + 10 minutes);
        _buy(alice, 0.009 ether);
        assertEq(data.lastBuyer(), address(0));
        assertEq(data.deadline(), T0 + 1 hours);
    }

    function test_sellDoesNotCount() public {
        _sell(alice);
        assertEq(data.lastBuyer(), address(0));
    }

    function test_buyAfterZeroDoesNotCount() public {
        _buy(alice, 1 ether);
        vm.warp(T0 + 1 hours);
        _buy(bob, 1 ether);
        assertEq(data.lastBuyer(), alice);
        assertTrue(data.roundEnded());
    }

    function test_hardDeadlineCapsGame() public {
        LastBuyerWinsCustomData.Params memory g = _game();
        g.extensionPerBuy = 1 days;
        g.maxRemaining = 1 days;
        g.maxGameDuration = 3 days;
        data = LastBuyerWinsCustomData(payable(Clones.clone(address(dataImpl))));
        token.setCustomData(address(data));
        data.init(address(token), address(core), abi.encode(g), "1.0.0");

        address last;
        uint256 t = T0;
        for (uint256 i = 0; i < 10; i++) {
            if (t >= data.deadline()) break;
            last = address(uint160(i + 1000));
            _buy(last, 1 ether);
            assertLe(data.deadline(), data.hardDeadline());
            t += 20 hours;
            vm.warp(t);
        }
        assertEq(data.deadline(), data.hardDeadline());
        vm.warp(data.hardDeadline());
        assertTrue(data.roundEnded());
        assertEq(data.lastBuyer(), last);
    }

    function test_onlyCoreHooks() public {
        vm.expectRevert("LBW: only fourCore");
        data.afterHook(OpenFourTypes.TradeHookContext(address(token), alice, 1, 1, true, 0, 0, 1 ether, 1 ether, ""));
        vm.expectRevert("LBW: only fourCore");
        data.onMigrate(OpenFourTypes.MigrateHookContext(address(vault), address(token), address(0), creator, 0, 0, 0));
    }

    function test_wrongTokenReverts() public {
        vm.prank(address(core));
        vm.expectRevert("LBW: wrong token");
        data.afterHook(OpenFourTypes.TradeHookContext(address(1), alice, 1, 1, true, 0, 0, 1 ether, 1 ether, ""));
    }

    function test_cannotReinit() public {
        vm.expectRevert();
        data.init(address(token), address(core), abi.encode(_game()), "1.0.0");
    }

    function test_implementationLocked() public {
        vm.expectRevert();
        dataImpl.init(address(token), address(core), abi.encode(_game()), "1.0.0");
    }

    function test_badParamsRejected() public {
        LastBuyerWinsCustomData d2 = LastBuyerWinsCustomData(payable(Clones.clone(address(dataImpl))));
        LastBuyerWinsCustomData.Params memory g = _game();
        g.winnerBps = 4_999;
        vm.expectRevert("LBW: bad winnerBps");
        d2.init(address(token), address(core), abi.encode(g), "1");
        g = _game();
        g.maxRemaining = 10 minutes;
        vm.expectRevert("LBW: bad maxRemaining");
        d2.init(address(token), address(core), abi.encode(g), "1");
        g = _game();
        g.initialDuration = 1 minutes;
        vm.expectRevert("LBW: initialDuration too short");
        d2.init(address(token), address(core), abi.encode(g), "1");
    }

    // ---------------- migration ----------------

    function test_soldOutMigrationClosesRound() public {
        _buy(alice, 1 ether);
        vm.warp(T0 + 5 minutes);
        vm.prank(address(core));
        data.onMigrate(OpenFourTypes.MigrateHookContext(address(vault), address(token), address(0), creator, 10 ether, 0, block.timestamp));
        assertTrue(data.roundEnded());
        assertEq(data.deadline(), T0 + 5 minutes);
        _buy(bob, 1 ether); // ignored after migration
        assertEq(data.lastBuyer(), alice);
    }

    function test_migrateEvaluate() public {
        OpenFourTypes.MigrateContext memory ctx = OpenFourTypes.MigrateContext(address(token), 1 ether, 1, false, block.timestamp);
        vm.prank(address(core));
        assertFalse(migrate.evaluate(ctx).canMigrate);

        vault.setSoldOut(true);
        ctx.soldOut = true;
        vm.prank(address(core));
        assertTrue(migrate.evaluate(ctx).canMigrate);

        vault.setSoldOut(false);
        ctx.soldOut = false;
        vm.warp(T0 + 1 hours);
        ctx.timestamp = block.timestamp;
        vm.prank(address(core));
        assertTrue(migrate.evaluate(ctx).canMigrate);
        assertTrue(migrate.canMigrateNow());
    }

    function test_executeMigrationRechecks() public {
        OpenFourTypes.MigrateHookContext memory ctx =
            OpenFourTypes.MigrateHookContext(address(vault), address(token), address(0), creator, 1 ether, 1, block.timestamp);
        vm.prank(address(core));
        vm.expectRevert("LBWMigrate: conditions not met");
        migrate.executeMigration(ctx, "");

        vm.expectRevert("LBWMigrate: only fourCore");
        migrate.executeMigration(ctx, "");

        vm.warp(T0 + 1 hours);
        ctx.timestamp = block.timestamp;
        vm.prank(address(core));
        (uint8 v,) = migrate.executeMigration(ctx, "");
        assertEq(v, 0);
    }

    // ---------------- trade ----------------

    function test_tradeRoutesFeeToPot() public view {
        OpenFourTypes.TradeResult memory r = trade.evaluate(_tradeCtx(true));
        assertTrue(r.allowed);
        assertEq(r.fees.length, 1);
        assertEq(r.fees[0].recipient, address(data));
        assertEq(r.fees[0].bps, 100);
        assertEq(r.maxAmount, type(uint256).max);

        r = trade.evaluate(_tradeCtx(false));
        assertEq(r.fees[0].bps, 200);
    }

    function test_tradePostRoundCap() public {
        vm.warp(T0 + 2 hours);
        OpenFourTypes.TradeResult memory r = trade.evaluate(_tradeCtx(true));
        assertTrue(r.allowed);
        assertEq(r.maxAmount, 1 ether);
    }

    function test_tradeBlockedWithoutData() public {
        token.setCustomData(address(0));
        OpenFourTypes.TradeResult memory r = trade.evaluate(_tradeCtx(true));
        assertFalse(r.allowed);
    }

    function test_tradeFeeCeiling() public {
        LastBuyerWinsTradeModule t2 = LastBuyerWinsTradeModule(Clones.clone(address(tradeImpl)));
        vm.expectRevert("LBWTrade: fee too high");
        t2.init(address(token), address(core), abi.encode(LastBuyerWinsTradeModule.TradeConfig(1001, 0, 0, 1)), "1");
    }

    // ---------------- settlement ----------------

    function test_settleNative() public {
        _buy(alice, 1 ether);
        vm.deal(address(data), 10 ether);
        vm.expectRevert("LBW: round live");
        data.settle();

        vm.warp(T0 + 1 hours);
        data.settle();
        assertEq(alice.balance, 9 ether);
        assertEq(creator.balance, 1 ether);
        assertEq(address(data).balance, 0);

        // late fees (e.g. the graduation-trigger buy) can be swept again
        vm.deal(address(data), 1 ether);
        data.settle();
        assertEq(alice.balance, 9.9 ether);
        assertEq(data.totalPaidToWinner(), 9.9 ether);
    }

    function test_settleWrappedNativeAndNative() public {
        _buy(alice, 1 ether);
        vm.deal(address(this), 2 ether);
        wbnb.deposit{value: 2 ether}();
        wbnb.transfer(address(data), 2 ether);
        vm.deal(address(data), 1 ether);
        vm.warp(T0 + 1 hours);
        data.settle();
        assertEq(wbnb.balanceOf(alice), 1.8 ether);
        assertEq(alice.balance, 0.9 ether);
    }

    function test_settleErc20Quote() public {
        MockUSD usd = new MockUSD();
        _deploy(address(usd));
        _buy(bob, 1 ether);
        usd.mint(address(data), 1000e18);
        vm.warp(T0 + 1 hours);
        data.settle();
        assertEq(usd.balanceOf(bob), 900e18);
        assertEq(usd.balanceOf(creator), 100e18);
    }

    function test_noBuyerPotGoesToCreator() public {
        vm.deal(address(data), 3 ether);
        vm.warp(T0 + 1 hours);
        data.settle();
        assertEq(creator.balance, 3 ether);
    }

    function test_rejectingWinnerGetsWrappedNative() public {
        NativeRejecter r = new NativeRejecter();
        _buy(address(r), 1 ether);
        vm.deal(address(data), 10 ether);
        vm.warp(T0 + 1 hours);
        data.settle();
        assertEq(wbnb.balanceOf(address(r)), 9 ether);
        assertEq(creator.balance, 1 ether);
    }

    function test_reentrancyBlocked() public {
        Reenterer r = new Reenterer();
        r.set(data);
        _buy(address(r), 1 ether);
        vm.deal(address(data), 10 ether);
        vm.warp(T0 + 1 hours);
        data.settle();
        assertTrue(r.tried());
        assertFalse(r.reentered());
        assertEq(address(data).balance, 0);
    }

    function testFuzz_deadlineNeverExceedsBounds(uint32[20] memory gaps, uint96[20] memory quotes) public {
        uint256 t = T0;
        for (uint256 i = 0; i < 20; i++) {
            t += uint256(gaps[i]) % 2 hours;
            vm.warp(t);
            _buy(address(uint160(i + 1)), quotes[i]);
            assertLe(data.deadline(), data.hardDeadline());
            if (!data.roundEnded()) assertLe(data.deadline() - block.timestamp, 1 hours);
        }
    }

    // ---------------- validator ----------------

    function _initParams() internal pure returns (OpenFourTypes.TokenInitParams memory p) {
        p.name = "LBW";
        p.symbol = "LBW";
        p.maxSupply = 1_000_000_000 ether;
        p.saleAmount = 800_000_000 ether;
        p.raiseAmount = 18 ether;
        p.customDataParams = abi.encode(_game());
        p.tradeParams = abi.encode(LastBuyerWinsTradeModule.TradeConfig(100, 200, 0, 1 ether));
        p.migrateParams = abi.encode(LastBuyerWinsMigrateModule.Params(address(0xAD), address(0xdEaD), 200_000_000 ether, 0));
    }

    function test_validatorAccepts() public {
        LastBuyerWinsPresetValidator v = new LastBuyerWinsPresetValidator(42);
        v.validate(42, _initParams());
    }

    function test_validatorRejects() public {
        LastBuyerWinsPresetValidator v = new LastBuyerWinsPresetValidator(42);
        OpenFourTypes.TokenInitParams memory p = _initParams();
        vm.expectRevert("LBWVal: wrong preset");
        v.validate(1, p);

        p.migrateParams = abi.encode(LastBuyerWinsMigrateModule.Params(address(0xAD), address(0xdEaD), 300_000_000 ether, 0));
        vm.expectRevert("LBWVal: liquidity > reserve");
        v.validate(42, p);

        p = _initParams();
        LastBuyerWinsCustomData.Params memory g = _game();
        g.minQualifyingQuote = 5 ether;
        p.customDataParams = abi.encode(g);
        vm.expectRevert("LBWVal: qualifying buy too large");
        v.validate(42, p);
    }

    function test_descriptorsAndSchemas() public view {
        (, string memory tag,) = data.descriptor();
        assertEq(tag, "module.data.last_buyer_wins");
        (, tag,) = trade.descriptor();
        assertEq(tag, "module.trade.last_buyer_wins");
        (, tag,) = migrate.descriptor();
        assertEq(tag, "module.migrate.last_buyer_wins");
        assertEq(data.moduleEncodeSchema().params.length, 6);
        assertEq(trade.moduleEncodeSchema().params.length, 4);
        assertEq(migrate.moduleEncodeSchema().params.length, 4);
    }
}
