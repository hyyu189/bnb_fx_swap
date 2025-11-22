// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";

contract PriceOracleTest is Test {
    PriceOracle oracle;
    MockV3Aggregator mockFeed;

    function setUp() public {
        // deployed mock with 8 decimals (standard for Chainlink USD feeds) and price of $300
        mockFeed = new MockV3Aggregator(8, 300 * 10**8);
        oracle = new PriceOracle(address(mockFeed));
    }

    function test_GetLatestPrice_Scaling() public view {
        uint256 price = oracle.getLatestPrice();
        // Should scale up to 18 decimals
        assertEq(price, 300 * 10**18);
    }

    function test_GetLatestPrice_Stale() public {
        // Warp time forward past TIMEOUT (3 hours)
        vm.warp(block.timestamp + 3 hours + 1 seconds);
        
        vm.expectRevert("Stale price data");
        oracle.getLatestPrice();
    }

    function test_GetLatestPrice_Negative() public {
        mockFeed.updateAnswer(-100);
        vm.expectRevert("Invalid price");
        oracle.getLatestPrice();
    }
}
