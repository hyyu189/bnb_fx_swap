// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title bUSD
 * @dev Synthetic Dollar backed by BNB collateral.
 * Controlled by the FXSwapVault (Owner).
 */
contract bUSD is ERC20, ERC20Burnable, Ownable, ERC20Permit {
    constructor(address initialOwner) 
        ERC20("Synthetic BNB Dollar", "bUSD") 
        Ownable(initialOwner) 
        ERC20Permit("Synthetic BNB Dollar")
    {}

    /**
     * @dev Mints new bUSD tokens.
     * Only callable by the owner (The Vault).
     * @param to The address to receive the minted tokens.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}
