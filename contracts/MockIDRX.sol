// SPDX-License-Identifier: MIT
pragma solidity 0.8.20; // FIXED: Mengunci Pragma Version

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockIDRX
 * @dev Mock IDRX token untuk testing di Base Sepolia. Digunakan untuk simulasi Top Up.
 * @notice 1 IDRX = 1 Indonesian Rupiah
 * 18 decimals (standard ERC20)
 */
contract MockIDRX is ERC20, ERC20Permit, Ownable {
    uint8 private constant _decimals = 18;

    // FIXED: Meneruskan initialOwner ke constructor Ownable
    constructor(
        address initialOwner
    )
        ERC20("Indonesian Rupiah X", "IDRX")
        ERC20Permit("Indonesian Rupiah X")
        Ownable(initialOwner)
    {
        // Mint 1 miliar IDRX untuk Owner (Server Wallet) sebagai initial liquidity
        _mint(initialOwner, 1_000_000_000 * 10 ** _decimals);
    }

    function decimals() public pure override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice [CUSTODIAL PAYMENT] Mensimulasikan Top Up Rupiah.
     * @dev HANYA dipanggil oleh Server Wallet (Owner) untuk mencetak IDRX ke Wallet Custodial User.
     * @param _to Alamat wallet Custodial User yang akan menerima IDRX.
     * @param _amount Jumlah IDRX (dalam unit terkecil 18 decimals) yang di-top-up.
     */
    function mockPayment(address _to, uint256 _amount) external onlyOwner {
        // Dibatasi Owner
        require(_to != address(0), "Invalid recipient address");
        require(_amount != 0, "Amount must be non-zero");
        // Mencetak IDRX langsung ke custodial wallet user
        _mint(_to, _amount);
    }

    /**
     * @notice Faucet: Memberikan 1 juta IDRX gratis untuk testing developer (dapat dipanggil siapa saja).
     */
    function faucet() external {
        uint256 faucetAmount = 1_000_000 * 10 ** _decimals;
        _mint(msg.sender, faucetAmount);
    }

    /**
     * @dev Fungsi mint generik, dibatasi hanya untuk Owner (Server Wallet) sebagai kontrol.
     */
    function ownerMint(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient address");
        _mint(to, amount);
    }
}
