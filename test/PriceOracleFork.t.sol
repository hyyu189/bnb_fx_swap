// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

contract PriceOracleForkTest is Test {
    PriceOracle oracle;
    // BNB/USD Chainlink Feed on BSC Mainnet
    address constant BNB_USD_FEED = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    string constant BSC_RPC_URL = "https://binance.llamarpc.com";

    function setUp() public {
        // Only run if we can fork
        try vm.createSelectFork(BSC_RPC_URL) {
            oracle = new PriceOracle(BNB_USD_FEED);
        } catch {
            console.log("Skipping fork test: Could not connect to BSC RPC");
            return;
        }
    }

    function test_Fork_GetLatestPrice() public view {
        // Skip if not on a fork
        if (address(oracle) == address(0)) return;

        uint256 price = oracle.getLatestPrice();
        console.log("Current BNB Price (18 decimals):", price);
        
        // Sanity check: Price should be > 0
        assertTrue(price > 0);
        
        // Sanity check: BNB is likely between $100 and $10,000 (100e18 - 10000e18)
        // Adjust bounds as per market conditions, this is just to catch garbage data
        assertTrue(price > 100 * 1e18); 
        assertTrue(price < 10000 * 1e18);
    }

    function test_Fork_Decimals() public view {
        if (address(oracle) == address(0)) return;

        // Chainlink BNB/USD feed is 8 decimals
        uint8 decimals = oracle.getDecimals();
        assertEq(decimals, 8);
    }
}
