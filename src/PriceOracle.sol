// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/**
 * @title PriceOracle
 * @dev Wrapper around Chainlink AggregatorV3 to fetch BNB/USD price.
 */
contract PriceOracle {
    AggregatorV3Interface internal priceFeed;
    uint256 public constant TIMEOUT = 3 hours; // Check for stale data

    constructor(address _priceFeed) {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    /**
     * @notice Returns the latest price of BNB in USD, scaled to 18 decimals.
     * @return price The latest price (18 decimals).
     */
    function getLatestPrice() public view returns (uint256) {
        (
            , 
            int256 price, 
            , 
            uint256 updatedAt, 
            
        ) = priceFeed.latestRoundData();

        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt < TIMEOUT, "Stale price data");

        // Chainlink BNB/USD usually has 8 decimals.
        // We want to return 18 decimals for consistency with standard ERC20s (like bUSD).
        uint8 decimals = priceFeed.decimals();
        
        if (decimals < 18) {
            return uint256(price) * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return uint256(price) / (10 ** (decimals - 18));
        }
        
        return uint256(price);
    }

    function getDecimals() external view returns (uint8) {
        return priceFeed.decimals();
    }
}
