// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {FXSwapVault} from "../src/FXSwapVault.sol";
import {bUSD} from "../src/bUSD.sol";
import {PriceOracle} from "../src/PriceOracle.sol";
import {MockV3Aggregator} from "../src/mocks/MockV3Aggregator.sol";

contract FXSwapVaultTest is Test {
    FXSwapVault vault;
    bUSD busdToken;
    PriceOracle oracle;
    MockV3Aggregator mockFeed;

    address user = address(0x1);
    uint256 constant BNB_PRICE = 300 * 1e8; // $300
    uint256 constant INITIAL_COLLATERAL = 10 ether; // 10 BNB

    function setUp() public {
        // 1. Setup Oracle
        mockFeed = new MockV3Aggregator(8, int256(BNB_PRICE));
        oracle = new PriceOracle(address(mockFeed));

        // 2. Setup bUSD (Deployer is owner initially)
        busdToken = new bUSD(address(this));

        // 3. Setup Vault
        vault = new FXSwapVault(address(busdToken), address(oracle));

        // 4. Transfer bUSD ownership to Vault so it can mint
        busdToken.transferOwnership(address(vault));

        // 5. Fund User
        vm.deal(user, 100 ether);
    }

    function test_OpenPosition() public {
        vm.startPrank(user);

        uint256 collateral = 1 ether; // $300 value
        // Max Borrow (LTV 66%) = $300 * 0.66 = $198
        uint256 debt = 150 * 1e18; // Borrowing $150 (safe)

        vault.openPosition{value: collateral}(debt, 7 days);

        // Check Position
        (address owner, uint256 col, uint256 d, uint256 start, uint256 mat, bool open) = vault.positions(0);
        
        assertEq(owner, user);
        assertEq(col, collateral);
        assertEq(d, debt);
        assertEq(mat, start + 7 days);
        assertTrue(open);

        // Check Token Balance
        assertEq(busdToken.balanceOf(user), debt);
        vm.stopPrank();
    }

    function test_OpenPosition_RevertLTV() public {
        vm.startPrank(user);
        uint256 collateral = 1 ether; // $300 value
        // Limit is $198. Try borrowing $200.
        uint256 debt = 200 * 1e18; 

        vm.expectRevert("Insufficient collateral for LTV");
        vault.openPosition{value: collateral}(debt, 7 days);
        vm.stopPrank();
    }

    function test_RepayPosition() public {
        vm.startPrank(user);
        
        // Open
        uint256 collateral = 1 ether;
        uint256 debt = 100 * 1e18;
        vault.openPosition{value: collateral}(debt, 7 days);

        // Approve Vault to burn bUSD
        busdToken.approve(address(vault), debt);

        // Repay
        uint256 balBefore = user.balance;
        vault.repayPosition(0);
        uint256 balAfter = user.balance;

        // Checks
        assertEq(balAfter, balBefore + collateral);
        assertEq(busdToken.balanceOf(user), 0);
        
        // Position Closed
        (,,,,, bool open) = vault.positions(0);
        assertFalse(open);
        
        vm.stopPrank();
    }

    function test_AddCollateral() public {
        vm.startPrank(user);
        // Open position
        vault.openPosition{value: 1 ether}(100 * 1e18, 7 days);
        
        // Add more
        vault.addCollateral{value: 1 ether}(0);
        
        (, uint256 col,,,,) = vault.positions(0);
        assertEq(col, 2 ether);
        vm.stopPrank();
    }
}
