// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LastBuyerWinsCustomData} from "../src/LastBuyerWinsCustomData.sol";
import {LastBuyerWinsTradeModule} from "../src/LastBuyerWinsTradeModule.sol";
import {LastBuyerWinsMigrateModule} from "../src/LastBuyerWinsMigrateModule.sol";
import {OpenFourTypes} from "../src/openfour/libraries/OpenFourTypes.sol";
import {MockWBNB, MockVault, MockToken} from "./LastBuyerWins.t.sol";

/// @dev Simplified stand-in for OpenFourCore's buy path, in the documented order:
///      trade.evaluate -> fee tiers paid -> customData.afterHook -> migrate.evaluate -> executeMigration -> onMigrate.
contract SimCore {
    address public creator;
    address public wrappedNative;
    MockToken public token;
    MockVault public vault;
    LastBuyerWinsTradeModule public trade;
    LastBuyerWinsMigrateModule public migrate;
    LastBuyerWinsCustomData public data;
    bool public migrated;
    uint256 public totalRaised;

    constructor(address creator_, address wnative_) {
        creator = creator_;
        wrappedNative = wnative_;
    }

    function wire(MockToken t, MockVault v, LastBuyerWinsTradeModule tr, LastBuyerWinsMigrateModule m, LastBuyerWinsCustomData d)
        external
    {
        token = t;
        vault = v;
        trade = tr;
        migrate = m;
        data = d;
    }

    function tokens(address t) external view returns (
        uint32, address, uint256, address, string memory, string memory, uint256, uint256, uint256, address,
        address, address, address, address, address, address, uint256, bool, bool, bool
    ) {
        return (1, creator, 1, t, "", "", 0, 0, 0, address(0), address(vault), address(0), address(0), address(0), address(0), address(data), 0, true, false, false);
    }

    /// @param curveQuote price of `amount` from the curve (simulated, flat).
    function buy(uint256 amount, uint256 curveQuote) external payable {
        require(!migrated, "SimCore: migrated");
        OpenFourTypes.TradeResult memory r = trade.evaluate(OpenFourTypes.TradeContext({
            token: address(token), trader: msg.sender, amount: amount, isBuy: true, timestamp: block.timestamp,
            blockNumber: block.number, remainingForSale: 0, totalRaised: totalRaised, curveQuote: curveQuote, proof: ""
        }));
        require(r.allowed, r.reason);
        uint256 executed = amount > r.maxAmount ? r.maxAmount : amount;
        uint256 quote = curveQuote * executed / amount;
        uint256 fee;
        for (uint256 i = 0; i < r.fees.length; i++) {
            uint256 f = quote * r.fees[i].bps / 10_000;
            fee += f;
            (bool ok,) = r.fees[i].recipient.call{value: f}("");
            require(ok, "SimCore: fee push failed");
        }
        require(msg.value >= quote + fee, "SimCore: underpaid");
        totalRaised += quote;
        if (msg.value > quote + fee) payable(msg.sender).transfer(msg.value - quote - fee);

        data.afterHook(OpenFourTypes.TradeHookContext({
            token: address(token), trader: msg.sender, requestedAmount: amount, executedAmount: executed, isBuy: true,
            timestamp: block.timestamp, blockNumber: block.number, curveQuote: quote, traderQuote: quote + fee, proof: ""
        }));

        OpenFourTypes.MigrateResult memory m = migrate.evaluate(OpenFourTypes.MigrateContext({
            token: address(token), totalRaised: totalRaised, remainingForSale: 1, soldOut: vault.isSoldOut(), timestamp: block.timestamp
        }));
        if (m.canMigrate) {
            OpenFourTypes.MigrateHookContext memory h = OpenFourTypes.MigrateHookContext({
                vault: address(vault), token: address(token), quoteAsset: address(0), creator: creator,
                totalRaised: totalRaised, remainingForSale: 0, timestamp: block.timestamp
            });
            migrate.executeMigration(h, m.data);
            data.onMigrate(h);
            migrated = true;
        }
    }

    receive() external payable {}
}

contract EndToEndTest is Test {
    SimCore core;
    LastBuyerWinsCustomData data;
    MockVault vault;
    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);
    uint256 constant T0 = 1_800_000_000;

    function setUp() public {
        vm.warp(T0);
        MockWBNB wbnb = new MockWBNB();
        vault = new MockVault();
        MockToken token = new MockToken(address(vault));
        core = new SimCore(creator, address(wbnb));

        data = LastBuyerWinsCustomData(payable(Clones.clone(address(new LastBuyerWinsCustomData()))));
        LastBuyerWinsTradeModule trade = LastBuyerWinsTradeModule(Clones.clone(address(new LastBuyerWinsTradeModule())));
        LastBuyerWinsMigrateModule migrate = LastBuyerWinsMigrateModule(Clones.clone(address(new LastBuyerWinsMigrateModule())));
        token.setCustomData(address(data));
        core.wire(token, vault, trade, migrate, data);

        data.init(address(token), address(core), abi.encode(LastBuyerWinsCustomData.Params(1 hours, 60, 1 hours, 7 days, 0.01 ether, 9_000)), "1.0.0");
        trade.init(address(token), address(core), abi.encode(LastBuyerWinsTradeModule.TradeConfig(100, 200, 0, 1 ether)), "1.0.0");
        migrate.init(address(token), address(core), address(0), abi.encode(LastBuyerWinsMigrateModule.Params(address(0), address(0), 0, 0)), "1.0.0");

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    function test_fullGame_timerEnds() public {
        vm.prank(alice);
        core.buy{value: 1.01 ether}(100 ether, 1 ether);        // fee 0.01
        vm.warp(T0 + 50 minutes);
        vm.prank(bob);
        core.buy{value: 2.02 ether}(200 ether, 2 ether);        // fee 0.02, becomes last buyer
        vm.warp(T0 + 55 minutes);
        vm.prank(carol);
        core.buy{value: 0.00505 ether}(1 ether, 0.005 ether);   // too small to count

        assertEq(data.lastBuyer(), bob);
        LastBuyerWinsCustomData.GameState memory s = data.gameState();
        assertEq(s.deadline, T0 + 1 hours + 60);
        assertEq(s.potNative, 0.03005 ether);

        // clock hits zero; carol's tiny buy triggers graduation but cannot win
        vm.warp(T0 + 1 hours + 60);
        vm.prank(carol);
        core.buy{value: 1.01 ether}(1 ether, 1 ether);
        assertTrue(core.migrated());
        assertEq(data.lastBuyer(), bob);

        uint256 pot = address(data).balance;
        uint256 bobBefore = bob.balance;
        vm.prank(alice); // anyone can settle
        data.settle();
        assertEq(bob.balance - bobBefore, pot * 9_000 / 10_000);
        assertEq(creator.balance, pot - pot * 9_000 / 10_000);
        assertEq(address(data).balance, 0);
    }

    function test_fullGame_soldOutEndsEarly() public {
        vm.prank(alice);
        core.buy{value: 1.01 ether}(100 ether, 1 ether);
        vm.warp(T0 + 10 minutes);
        vault.setSoldOut(true);
        vm.prank(bob);
        core.buy{value: 1.01 ether}(100 ether, 1 ether);
        assertTrue(core.migrated());
        assertTrue(data.roundEnded());
        assertEq(data.lastBuyer(), bob);
        data.settle();
        assertEq(creator.balance, 0.002 ether);
    }

    function test_postRoundBuyIsCapped() public {
        vm.warp(T0 + 2 hours);
        vm.prank(alice);
        core.buy{value: 10.1 ether}(10 ether, 10 ether); // capped to postRoundMaxBuy = 1 ether of tokens
        assertTrue(core.migrated());
        assertEq(core.totalRaised(), 1 ether);
        assertEq(data.lastBuyer(), address(0));
        data.settle();
        assertEq(creator.balance, 0.01 ether); // nobody qualified -> creator
    }
}
