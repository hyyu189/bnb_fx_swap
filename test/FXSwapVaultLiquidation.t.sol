// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {FXSwapVault} from "../src/FXSwapVault.sol";
import {bUSD} from "../src/bUSD.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";

contract FXSwapVaultLiquidationTest is Test {
    FXSwapVault vault;
    bUSD busdToken;
    PriceOracle oracle;
    MockV3Aggregator mockFeed;

    address user = address(0x1);
    address liquidator = address(0x2);
    address owner = address(this);

    uint256 constant BNB_PRICE_INITIAL = 300 * 1e8; // $300
    uint256 constant INITIAL_COLLATERAL = 10 ether; 

    function setUp() public {
        // 1. Setup Oracle
        mockFeed = new MockV3Aggregator(8, int256(BNB_PRICE_INITIAL));
        oracle = new PriceOracle(address(mockFeed));

        // 2. Setup bUSD
        busdToken = new bUSD(address(this));

        // 3. Setup Vault
        vault = new FXSwapVault(address(busdToken), address(oracle));
        busdToken.transferOwnership(address(vault));

        // 4. Fund User & Liquidator
        vm.deal(user, 100 ether);
        vm.deal(liquidator, 100 ether);
    }

    function test_Liquidation_HealthFactor() public {
        // 1. User opens position
        vm.startPrank(user);
        uint256 collateral = 1 ether; // $300 value
        // LTV 66% => Max Debt $198. Let's borrow $180.
        uint256 debt = 180 * 1e18; 
        vault.openPosition{value: collateral}(debt, 30 days);
        vm.stopPrank();

        // 2. Price Drops to $200
        // Collateral Value = $200.
        // Liquidation Threshold = 80% (125% C-Ratio) => $200 * 0.8 = $160 liquidation value.
        // Debt = $180.
        // Health Factor = 160 / 180 = 0.88 (< 1.0) -> Liquidatable!
        mockFeed.updateAnswer(200 * 1e8);

        // 3. Liquidator prepares
        // Liquidator needs bUSD to pay off debt. 
        // In a real scenario, they might flash loan or swap. 
        // Here we mint them some for testing setup (simulating they bought it on market).
        vm.prank(address(vault)); // Vault owns bUSD, cheating slightly to fund liquidator
        busdToken.mint(liquidator, debt);

        vm.startPrank(liquidator);
        busdToken.approve(address(vault), debt);

        uint256 balLiqBefore = liquidator.balance;
        
        vault.liquidate(0);
        
        uint256 balLiqAfter = liquidator.balance;
        vm.stopPrank();

        // 4. Verify
        // Collateral Seized Calculation:
        // Debt covered = 180 bUSD
        // Price = $200
        // Base Collateral = 180 / 200 = 0.9 BNB
        // Bonus = 10%
        // Reward = 0.9 * 1.1 = 0.99 BNB
        
        uint256 expectedReward = 0.99 ether;
        assertEq(balLiqAfter - balLiqBefore, expectedReward);

        // Position Closed
        (,,,,, bool isOpen) = vault.positions(0);
        assertFalse(isOpen);
    }

    function test_Liquidation_Expiration() public {
        // 1. User opens position (Safe LTV)
        vm.startPrank(user);
        uint256 collateral = 1 ether; // $300
        uint256 debt = 100 * 1e18; // $100 debt (Very safe)
        vault.openPosition{value: collateral}(debt, 7 days);
        vm.stopPrank();

        // 2. Warp past maturity
        vm.warp(block.timestamp + 8 days);
        
        // Update Oracle time so it's not stale
        mockFeed.updateRoundData(
            uint80(mockFeed.latestRound()), 
            mockFeed.latestAnswer(), 
            block.timestamp, 
            block.timestamp
        );

        // 3. Liquidator acts
        vm.prank(address(vault));
        busdToken.mint(liquidator, debt);

        vm.startPrank(liquidator);
        busdToken.approve(address(vault), debt);
        
        vault.liquidate(0);
        vm.stopPrank();

        // 4. Verify
        (,,,,, bool isOpen) = vault.positions(0);
        assertFalse(isOpen);
    }

    function test_Rollover() public {
        // 1. User opens position
        vm.startPrank(user);
        uint256 collateral = 1 ether; // $300
        uint256 debt = 150 * 1e18; // $150 (0.5 BNB worth)
        vault.openPosition{value: collateral}(debt, 7 days);
        
        (,,,, uint256 maturityBefore,) = vault.positions(0);

        // 2. Rollover
        // Fee = Debt(BNB) * Rate * Duration / 365 days
        // Debt(BNB) = 150/300 = 0.5 BNB
        // Rate = 5% (0.05)
        // Duration = 7 days
        // Fee = 0.5 * 0.05 * 7/365 ~= 0.000479 BNB
        
        // Let's send 0.01 BNB to be safe (excess refunded)
        uint256 extension = 7 days;
        vault.rollOver{value: 0.01 ether}(0, extension);

        (,,,, uint256 maturityAfter,) = vault.positions(0);
        
        assertEq(maturityAfter, maturityBefore + extension);
        vm.stopPrank();
    }

    // Allow test contract to receive ETH fees
    receive() external payable {}
}
