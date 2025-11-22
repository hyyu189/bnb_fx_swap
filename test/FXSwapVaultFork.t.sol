// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {FXSwapVault} from "../src/FXSwapVault.sol";
import {bUSD} from "../src/bUSD.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";

contract FXSwapVaultForkTest is Test {
    FXSwapVault vault;
    bUSD busdToken;
    PriceOracle realOracle;
    PriceOracle mockOracle;
    MockV3Aggregator mockFeed;

    // Real BNB Chain Addresses
    address constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    // Using official public node
    string constant BSC_RPC_URL = "https://bsc-dataseed.binance.org/";
    
    address user = address(0x123);
    address liquidator = address(0x456);

    function setUp() public {
        // Only run if we can fork
        try vm.createSelectFork(BSC_RPC_URL) {
            // 1. Setup Real Oracle Wrapper
            realOracle = new PriceOracle(BNB_USD_FEED);
            
            // 2. Setup Mock Oracle for Liquidation tests (on the fork)
            // Get current price from real feed to init mock
            uint256 currentPrice = realOracle.getLatestPrice(); 
            // Convert 18 decimals back to 8 for the mock
            int256 price8 = int256(currentPrice / 1e10);
            mockFeed = new MockV3Aggregator(8, price8);
            mockOracle = new PriceOracle(address(mockFeed));

            // 3. Setup bUSD
            busdToken = new bUSD(address(this));

            // 4. Setup Vault with Real Oracle initially
            vault = new FXSwapVault(address(busdToken), address(realOracle));

            // 5. Transfer ownership
            busdToken.transferOwnership(address(vault));

            // 6. Fund User
            vm.deal(user, 100 ether);
            vm.deal(liquidator, 100 ether);
        } catch {
            console.log("Skipping fork test: Could not connect to BSC RPC");
        }
    }

    // Happy Path with Mock Oracle (initialized with Real Data) to allow Time Warping
    function test_Fork_E2E_Open_Rollover_Repay() public {
        if (address(vault) == address(0)) return;

        // Use a vault with Mock Oracle for time-travel tests
        FXSwapVault mockVault = new FXSwapVault(address(busdToken), address(mockOracle));
        vm.prank(address(vault));
        busdToken.transferOwnership(address(mockVault));
        
        vm.startPrank(user);

        // 1. Check Price (Mock initialized with real price in setUp)
        uint256 price = mockOracle.getLatestPrice();
        console.log("BNB Price (Mock initialized):", price);

        // 2. Open Position
        uint256 collateral = 1 ether;
        uint256 collateralValue = (collateral * price) / 1e18;
        uint256 debt = collateralValue / 2; // 50% LTV
        
        mockVault.openPosition{value: collateral}(debt, 7 days);
        
        (,,, uint256 start, uint256 maturity, bool open) = mockVault.positions(0);
        assertTrue(open);
        assertEq(maturity, start + 7 days);
        assertEq(busdToken.balanceOf(user), debt);

        // 3. Rollover
        // Move forward 6 days
        vm.warp(block.timestamp + 6 days);

        // Update Mock Oracle timestamp to prevent Stale Price error
        mockFeed.updateRoundData(
            uint80(mockFeed.latestRound()), 
            mockFeed.latestAnswer(), 
            block.timestamp, 
            block.timestamp
        );
        
        // Rollover
        mockVault.rollOver{value: 0.1 ether}(0, 7 days);
        
        (,,,, uint256 maturityNew,) = mockVault.positions(0);
        assertEq(maturityNew, maturity + 7 days);

        // 4. Repay
        busdToken.approve(address(mockVault), debt);
        mockVault.repayPosition(0);
        
        (,,,,, bool openFinal) = mockVault.positions(0);
        assertFalse(openFinal);
        
        vm.stopPrank();
    }
    
    // Liquidation Path with Mock Oracle (still on Fork environment)
    function test_Fork_Liquidation_PriceDrop() public {
        if (address(vault) == address(0)) return;

        // Deploy a specific vault for this test using the Mock Oracle
        // so we can manipulate price
        FXSwapVault mockVault = new FXSwapVault(address(busdToken), address(mockOracle));
        
        // Prank the old vault to transfer ownership to the new mockVault
        vm.prank(address(vault));
        busdToken.transferOwnership(address(mockVault));

        vm.startPrank(user);
        
        // Open Position
        uint256 collateral = 1 ether;
        // Price is whatever real price was at setup
        uint256 price = mockOracle.getLatestPrice();
        uint256 debt = (collateral * price * 60) / 100 / 1e18; // 60% LTV (close to limit 66%)
        
        mockVault.openPosition{value: collateral}(debt, 30 days);
        vm.stopPrank();

        // Crash Price (drop 30%)
        int256 newPrice = int256(price * 70 / 100 / 1e10); // back to 8 decimals
        mockFeed.updateAnswer(newPrice);

        // Liquidate
        // Mint bUSD to liquidator (using prank on mockVault which is now owner)
        vm.prank(address(mockVault)); 
        busdToken.mint(liquidator, debt);

        vm.startPrank(liquidator);
        busdToken.approve(address(mockVault), debt);
        mockVault.liquidate(0);
        vm.stopPrank();

        (,,,,, bool open) = mockVault.positions(0);
        assertFalse(open);
    }

    // Allow test contract to receive ETH fees
    receive() external payable {}
}
