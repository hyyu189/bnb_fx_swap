// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {bUSD} from "./bUSD.sol";
import {PriceOracle} from "./PriceOracle.sol";

/**
 * @title FXSwapVault
 * @dev Core engine for the Synthetic BNB Dollar protocol.
 * Manages BNB collateral, issues bUSD, and tracks fixed-term swap positions.
 */
contract FXSwapVault is ReentrancyGuard, Ownable {
    /* ==================== STATE VARIABLES ==================== */

    bUSD public immutable busd;
    PriceOracle public immutable oracle;

    // Collateralization Parameters
    uint256 public constant MAX_LTV = 66e16; // 66% (150% C-Ratio)
    uint256 public constant LIQUIDATION_THRESHOLD = 80e16; // 80% (125% C-Ratio)
    uint256 public constant LIQUIDATION_BONUS = 10e16; // 10% Bonus for liquidators
    uint256 public constant ROLLOVER_RATE_APR = 5e16; // 5% APR for Rollovers
    
    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 365 days;

    struct Position {
        address owner;
        uint256 collateralAmount; // Amount of BNB
        uint256 debtAmount;       // Amount of bUSD minted
        uint256 startTime;
        uint256 maturityTimestamp;
        bool isOpen;
    }

    // Mapping from Position ID to Position data
    mapping(uint256 => Position) public positions;
    mapping(address => uint256[]) public userPositionIds;
    uint256 public nextPositionId;

    // Events
    event PositionOpened(uint256 indexed positionId, address indexed owner, uint256 collateral, uint256 debt, uint256 maturity);
    event PositionRepaid(uint256 indexed positionId, address indexed owner, uint256 debtRepaid, uint256 collateralReturned);
    event CollateralAdded(uint256 indexed positionId, uint256 amount);
    event PositionLiquidated(uint256 indexed positionId, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);
    event PositionRolled(uint256 indexed positionId, uint256 addedDuration, uint256 feePaid);

    /* ==================== CONSTRUCTOR ==================== */

    constructor(address _busd, address _oracle) Ownable(msg.sender) {
        busd = bUSD(_busd);
        oracle = PriceOracle(_oracle);
    }

    /* ==================== EXTERNAL FUNCTIONS ==================== */

    /**
     * @notice Opens a new Swap Position (Spot Leg).
     * @dev User deposits BNB and mints bUSD.
     * @param mintAmount The amount of bUSD to borrow/mint.
     * @param durationSeconds The duration of the swap in seconds.
     */
    function openPosition(uint256 mintAmount, uint256 durationSeconds) external payable nonReentrant {
        require(msg.value > 0, "Collateral required");
        require(mintAmount > 0, "Mint amount must be > 0");
        require(durationSeconds >= MIN_DURATION && durationSeconds <= MAX_DURATION, "Invalid duration");

        // 1. Calculate Collateral Value in USD
        uint256 collateralValueUsd = getCollateralValue(msg.value);

        // 2. Check LTV
        // debt / collateralValue <= MAX_LTV
        // => debt <= collateralValue * MAX_LTV
        require(mintAmount * 1e18 <= collateralValueUsd * MAX_LTV, "Insufficient collateral for LTV");

        // 3. Create Position
        uint256 pid = nextPositionId++;
        positions[pid] = Position({
            owner: msg.sender,
            collateralAmount: msg.value,
            debtAmount: mintAmount,
            startTime: block.timestamp,
            maturityTimestamp: block.timestamp + durationSeconds,
            isOpen: true
        });
        userPositionIds[msg.sender].push(pid);

        // 4. Mint bUSD to user
        busd.mint(msg.sender, mintAmount);

        emit PositionOpened(pid, msg.sender, msg.value, mintAmount, positions[pid].maturityTimestamp);
    }

    /**
     * @notice Repays a Swap Position (Forward Leg).
     * @dev User returns bUSD to unlock BNB.
     * @param positionId The ID of the position to repay.
     */
    function repayPosition(uint256 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.isOpen, "Position not open");
        require(pos.owner == msg.sender, "Not position owner");

        // 1. Burn bUSD from user
        // User must have approved vault or we use permit (standard transferFrom for now)
        // bUSD is Burnable, so if we are the owner or have allowance, we can burnFrom.
        // However, bUSD.burnFrom burns from 'account' and decreases allowance.
        // Here we transfer to vault then burn, or just burnFrom if Vault has role.
        // Simple approach: Transfer from user to Vault, then Vault burns.
        bool success = busd.transferFrom(msg.sender, address(this), pos.debtAmount);
        require(success, "bUSD transfer failed");
        busd.burn(pos.debtAmount);

        // 2. Return Collateral
        uint256 collateralReturn = pos.collateralAmount;
        
        // Update state before transfer
        pos.isOpen = false;
        pos.collateralAmount = 0;
        pos.debtAmount = 0;

        (bool sent, ) = payable(msg.sender).call{value: collateralReturn}("");
        require(sent, "BNB transfer failed");

        emit PositionRepaid(positionId, msg.sender, pos.debtAmount, collateralReturn);
    }

    /**
     * @notice Adds more collateral to an existing position to improve Health Factor.
     */
    function addCollateral(uint256 positionId) external payable nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.isOpen, "Position not open");
        require(msg.value > 0, "No value sent");

        pos.collateralAmount += msg.value;
        emit CollateralAdded(positionId, msg.value);
    }

    /**
     * @notice Liquidates an unsafe or expired position.
     * @dev Liquidator pays back bUSD debt and seizes BNB collateral with a bonus.
     * @param positionId The ID of the position to liquidate.
     */
    function liquidate(uint256 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.isOpen, "Position not open");

        // Check Triggers: Health Factor < 1.0 OR Expired
        uint256 health = getHealthFactor(positionId);
        bool isUnsafe = health < 1e18;
        bool isExpired = block.timestamp > pos.maturityTimestamp;

        require(isUnsafe || isExpired, "Position is healthy");

        uint256 debtToCover = pos.debtAmount;
        
        // Calculate Collateral to Seize
        // 1. Value of Debt in BNB = Debt(USD) / Price(USD/BNB)
        uint256 price = oracle.getLatestPrice(); // 18 decimals
        require(price > 0, "Invalid Oracle Price");

        uint256 baseCollateralNeeded = (debtToCover * 1e18) / price;
        uint256 rewardCollateral = (baseCollateralNeeded * (1e18 + LIQUIDATION_BONUS)) / 1e18;

        // Cap reward at available collateral (in case of deep underwater)
        if (rewardCollateral > pos.collateralAmount) {
            rewardCollateral = pos.collateralAmount;
        }

        // Execute Liquidation
        // 1. Burn bUSD from liquidator
        bool success = busd.transferFrom(msg.sender, address(this), debtToCover);
        require(success, "Transfer from liquidator failed");
        busd.burn(debtToCover);

        // 2. Distribute Collateral
        uint256 remainingCollateral = pos.collateralAmount - rewardCollateral;
        
        // Update State
        pos.isOpen = false;
        pos.debtAmount = 0;
        pos.collateralAmount = 0;

        // Send seized collateral to liquidator
        (bool sentLiq, ) = payable(msg.sender).call{value: rewardCollateral}("");
        require(sentLiq, "Transfer to liquidator failed");

        // Send remainder to original owner
        if (remainingCollateral > 0) {
            (bool sentOwner, ) = payable(pos.owner).call{value: remainingCollateral}("");
            require(sentOwner, "Transfer to owner failed");
        }

        emit PositionLiquidated(positionId, msg.sender, debtToCover, rewardCollateral);
    }

    /**
     * @notice Extends the duration of a position by paying a fee.
     * @param positionId The ID of the position.
     * @param addedDuration Seconds to add to maturity.
     */
    function rollOver(uint256 positionId, uint256 addedDuration) external payable nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.isOpen, "Position not open");
        require(pos.owner == msg.sender, "Not position owner");
        require(block.timestamp <= pos.maturityTimestamp, "Position expired");
        require(addedDuration >= MIN_DURATION, "Duration too short");
        require(pos.maturityTimestamp + addedDuration <= block.timestamp + MAX_DURATION, "Exceeds max duration");

        // Calculate Fee in BNB
        // Fee = Debt(BNB value) * APR * (Time / 365 days)
        uint256 price = oracle.getLatestPrice();
        uint256 debtInBNB = (pos.debtAmount * 1e18) / price;
        
        // Fee calculation: debtInBNB * rate * duration / (365 days)
        // Rate is scaled 1e16 (5% = 0.05e18? No, using 5e16 for 5%)
        // Let's ensure APR scaling is consistent. 
        // If ROLLOVER_RATE_APR = 5e16 (0.05), then:
        uint256 feeBNB = (debtInBNB * ROLLOVER_RATE_APR * addedDuration) / (365 days * 1e18);

        require(msg.value >= feeBNB, "Insufficient rollover fee");

        // Apply Update
        pos.maturityTimestamp += addedDuration;

        // Refund excess BNB
        if (msg.value > feeBNB) {
            (bool sentRefund, ) = payable(msg.sender).call{value: msg.value - feeBNB}("");
            require(sentRefund, "Refund failed");
        }

        // Send Fee to Protocol Owner
        (bool sentFee, ) = payable(owner()).call{value: feeBNB}("");
        require(sentFee, "Fee transfer failed");

        emit PositionRolled(positionId, addedDuration, feeBNB);
    }

    /* ==================== VIEW FUNCTIONS ==================== */

    /**
     * @notice Returns the USD value of a given BNB amount.
     * @param amountBNB Amount of BNB (18 decimals).
     * @return valueUsd Value in USD (18 decimals).
     */
    function getCollateralValue(uint256 amountBNB) public view returns (uint256) {
        uint256 price = oracle.getLatestPrice(); // 18 decimals
        // (amount * price) / 1e18
        return (amountBNB * price) / 1e18;
    }

    /**
     * @notice Returns the current Health Factor of a position.
     * HF = (Collateral Value * Liquidation Threshold) / Debt
     * HF < 1.0 means liquidatable.
     * @return healthFactor Scaled by 1e18.
     */
    function getHealthFactor(uint256 positionId) public view returns (uint256) {
        Position memory pos = positions[positionId];
        if (!pos.isOpen || pos.debtAmount == 0) return type(uint256).max;

        uint256 collateralValue = getCollateralValue(pos.collateralAmount);
        uint256 liquidationCollateralValue = (collateralValue * LIQUIDATION_THRESHOLD) / 1e18;

        return (liquidationCollateralValue * 1e18) / pos.debtAmount;
    }

    /**
     * @notice Helper to get position details
     */
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }

    /**
     * @notice Returns all position IDs for a specific user.
     */
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositionIds[user];
    }
}
