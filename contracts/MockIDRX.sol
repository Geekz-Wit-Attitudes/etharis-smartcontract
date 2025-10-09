// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockIDRX
 * @dev Mock IDRX token untuk testing di Base Sepolia
 * @notice 1 IDRX = 1 Indonesian Rupiah
 * 18 decimals (standard ERC20)
 */
contract MockIDRX is ERC20, Ownable {
    
    // Decimals (18 standard)
    uint8 private constant _decimals = 18;
    
    // Pass the deployer's address as the initial owner
    constructor() 
        ERC20("Indonesian Rupiah X", "IDRX") 
        Ownable(msg.sender) // 👈 FIX: Pass msg.sender to Ownable constructor
    {
        // Mint 1 billion IDRX for testing to the deployer (which is msg.sender)
        _mint(msg.sender, 1_000_000_000 * 10**_decimals);
    }
    
    /**
     * @dev Decimals override
     */
    function decimals() public pure override returns (uint8) {
        return _decimals;
    }
    
    /**
     * @dev Mint function untuk testing (anyone can mint)
     * @notice Untuk production, hapus function ini atau restrict ke owner
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    /**
     * @dev Faucet: beri 1 juta IDRX gratis untuk testing
     */
    function faucet() external {
        uint256 faucetAmount = 1_000_000 * 10**_decimals; // 1 juta IDRX
        _mint(msg.sender, faucetAmount);
    }
}