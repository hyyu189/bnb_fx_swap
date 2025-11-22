// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FXSwapVault} from "../src/FXSwapVault.sol";
import {bUSD} from "../src/bUSD.sol";
import {PriceOracle} from "../src/PriceOracle.sol";

contract Deploy is Script {
    // BNB Testnet Chainlink BNB/USD Aggregator
    // Source: https://docs.chain.link/data-feeds/price-feeds/addresses?network=bnb-chain&page=1
    address constant BNB_USD_AGGREGATOR = 0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy PriceOracle
        console.log("Deploying PriceOracle...");
        PriceOracle oracle = new PriceOracle(BNB_USD_AGGREGATOR);
        console.log("PriceOracle deployed at:", address(oracle));

        // 2. Deploy bUSD
        console.log("Deploying bUSD...");
        bUSD busd = new bUSD(deployer); // Explicitly set deployer as owner
        console.log("bUSD deployed at:", address(busd));

        // 3. Deploy FXSwapVault
        console.log("Deploying FXSwapVault...");
        FXSwapVault vault = new FXSwapVault(address(busd), address(oracle));
        console.log("FXSwapVault deployed at:", address(vault));

        // 4. Transfer bUSD ownership to Vault
        console.log("Transferring bUSD ownership to Vault...");
        busd.transferOwnership(address(vault));
        console.log("Ownership transferred.");

        vm.stopBroadcast();
    }
}
