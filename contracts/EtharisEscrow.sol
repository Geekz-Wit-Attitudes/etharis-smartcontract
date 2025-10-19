// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title EtharisEscrow
 * @author Etharis Team
 * @dev Escrow contract untuk sponsorship deals. Semua fungsi action hanya dapat dipanggil oleh Server Wallet (Owner).
 * @notice Menggunakan IDRX sebagai payment token (Indonesian Rupiah stablecoin).
 */
contract EtharisEscrow is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    IERC20 public idrxToken;
    uint256 public platformFeeBps = 250; // 2.5%
    uint256 public constant BPS_DENOMINATOR = 10000;
    uint256 public constant REVIEW_PERIOD = 72 hours;
    address public feeRecipient;

    enum ContractStatus {
        PENDING,
        ACTIVE,
        PENDING_REVIEW,
        DISPUTED,
        COMPLETED,
        CANCELLED
    }

    struct Deal {
        string dealId;
        address brand;
        address creator;
        uint256 amount;
        uint256 deadline;
        string briefHash;
        ContractStatus status;
        uint256 fundedAt;
        uint256 submittedAt;
        uint256 reviewDeadline;
        string contentUrl;
        bool exists;
    }

    mapping(string => Deal) public deals;
    mapping(address => string[]) public brandDeals;
    mapping(address => string[]) public creatorDeals;

    event DealCreated(
        string indexed dealId,
        address indexed brand,
        address indexed creator,
        uint256 amount,
        uint256 deadline
    );
    event DealFunded(
        string indexed dealId,
        address indexed brand,
        uint256 amount
    );
    event ContentSubmitted(
        string indexed dealId,
        address indexed creator,
        string contentUrl,
        uint256 reviewDeadline
    );
    event DealApproved(string indexed dealId, address indexed brand);
    event PaymentReleased(
        string indexed dealId,
        address indexed creator,
        uint256 amount,
        uint256 platformFee
    );
    event DisputeInitiated(
        string indexed dealId,
        address indexed brand,
        string reason
    );
    event DisputeResolved(
        string indexed dealId,
        address indexed creator,
        bool accepted8020,
        uint256 creatorAmount,
        uint256 brandRefund
    );
    event DealCancelled(
        string indexed dealId,
        address indexed initiator,
        uint256 refundAmount
    );
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    modifier onlyDealBrand(string memory _dealId, address _brand) {
        require(
            deals[_dealId].brand == _brand,
            "Invalid brand address for deal"
        );
        _;
    }

    modifier onlyDealCreator(string memory _dealId, address _creator) {
        require(
            deals[_dealId].creator == _creator,
            "Invalid creator address for deal"
        );
        _;
    }

    modifier dealExists(string memory _dealId) {
        require(deals[_dealId].exists, "Deal does not exist");
        _;
    }

    modifier inStatus(string memory _dealId, ContractStatus _status) {
        require(deals[_dealId].status == _status, "Invalid deal status");
        _;
    }

    constructor(
        address _idrxToken,
        address _feeRecipient,
        address _initialOwner
    ) Ownable(_initialOwner) {
        require(_idrxToken != address(0), "Invalid IDRX token address"); // FIXED: Zero Address Validation
        require(_feeRecipient != address(0), "Invalid fee recipient"); // FIXED: Zero Address Validation
        require(_initialOwner != address(0), "Invalid owner address"); // ADDED: Zero Address Validation

        idrxToken = IERC20(_idrxToken);
        feeRecipient = _feeRecipient;
    }

    // =================================================================
    // CUSTODIAL USER ACTIONS (Dipanggil oleh Server Wallet - onlyOwner)
    // =================================================================

    /**
     * @notice [CUSTODIAL] Brand membuat deal baru.
     */
    function createDeal(
        string memory _dealId,
        address _brandAddress,
        address _creatorAddress,
        uint256 _amount,
        uint256 _deadline,
        string memory _briefHash
    ) external onlyOwner whenNotPaused {
        // RESTRICTED: onlyOwner
        require(!deals[_dealId].exists, "Deal ID already exists");
        require(_creatorAddress != address(0), "Invalid creator address");
        require(_brandAddress != address(0), "Invalid brand address");
        require(_brandAddress != _creatorAddress, "Creator cannot be brand");
        require(_amount != 0, "Amount must be greater than 0");
        require(_deadline > block.timestamp, "Deadline must be in future");
        require(bytes(_briefHash).length != 0, "Brief hash required");

        deals[_dealId] = Deal({
            dealId: _dealId,
            brand: _brandAddress,
            creator: _creatorAddress,
            amount: _amount,
            deadline: _deadline,
            briefHash: _briefHash,
            status: ContractStatus.PENDING,
            fundedAt: 0,
            submittedAt: 0,
            reviewDeadline: 0,
            contentUrl: "",
            exists: true
        });

        brandDeals[_brandAddress].push(_dealId);
        creatorDeals[_creatorAddress].push(_dealId);

        emit DealCreated(
            _dealId,
            _brandAddress,
            _creatorAddress,
            _amount,
            _deadline
        );
    }

    /**
     * @notice [CUSTODIAL] Brand fund deal.
     */
    function fundDeal(
        string memory _dealId,
        address _brandAddress
    )
        external
        nonReentrant
        onlyOwner
        whenNotPaused
        dealExists(_dealId)
        onlyDealBrand(_dealId, _brandAddress)
        inStatus(_dealId, ContractStatus.PENDING)
    {
        Deal storage deal = deals[_dealId];

        idrxToken.safeTransferFrom(_brandAddress, address(this), deal.amount);

        deal.status = ContractStatus.ACTIVE;
        deal.fundedAt = block.timestamp;

        emit DealFunded(_dealId, _brandAddress, deal.amount);
    }

    /**
     * @notice [CUSTODIAL] Creator submit konten.
     */
    function submitContent(
        string memory _dealId,
        address _creatorAddress,
        string memory _contentUrl
    )
        external
        onlyOwner // RESTRICTED: onlyOwner
        whenNotPaused
        dealExists(_dealId)
        onlyDealCreator(_dealId, _creatorAddress)
        inStatus(_dealId, ContractStatus.ACTIVE)
    {
        Deal storage deal = deals[_dealId];

        require(
            block.timestamp <= deal.deadline,
            "Submission deadline has passed. Deal is auto-cancelled."
        );

        require(bytes(_contentUrl).length != 0, "Content URL required"); // FIXED: Cheaper Conditional

        deal.status = ContractStatus.PENDING_REVIEW;
        deal.submittedAt = block.timestamp;
        deal.reviewDeadline = block.timestamp + REVIEW_PERIOD;
        deal.contentUrl = _contentUrl;

        emit ContentSubmitted(
            _dealId,
            _creatorAddress,
            _contentUrl,
            deal.reviewDeadline
        );
    }

    /**
     * @notice [CUSTODIAL] Brand approve content & release payment.
     */
    function approveDeal(
        string memory _dealId,
        address _brandAddress
    )
        external
        nonReentrant // FIXED: Pindahkan nonReentrant ke posisi awal
        onlyOwner // RESTRICTED: onlyOwner
        whenNotPaused
        dealExists(_dealId)
        onlyDealBrand(_dealId, _brandAddress)
        inStatus(_dealId, ContractStatus.PENDING_REVIEW)
    {
        emit DealApproved(_dealId, _brandAddress);
        _releasePayment(_dealId);
    }

    /**
     * @notice Auto-release payment.
     */
    function autoReleasePayment(
        string memory _dealId
    )
        external
        nonReentrant // FIXED: Pindahkan nonReentrant ke posisi awal
        whenNotPaused
        dealExists(_dealId)
        inStatus(_dealId, ContractStatus.PENDING_REVIEW)
    {
        Deal storage deal = deals[_dealId];
        require(
            block.timestamp >= deal.reviewDeadline,
            "Review period not ended"
        );

        _releasePayment(_dealId);
    }

    /**
     * @dev Internal function untuk release payment
     */
    function _releasePayment(string memory _dealId) internal {
        Deal storage deal = deals[_dealId];

        uint256 platformFee = (deal.amount * platformFeeBps) / BPS_DENOMINATOR;
        uint256 creatorAmount = deal.amount - platformFee;

        deal.status = ContractStatus.COMPLETED;

        // FIXED: Menggunakan SafeERC20.safeTransfer
        idrxToken.safeTransfer(deal.creator, creatorAmount);

        // FIXED: Menggunakan SafeERC20.safeTransfer
        idrxToken.safeTransfer(feeRecipient, platformFee);

        emit PaymentReleased(_dealId, deal.creator, creatorAmount, platformFee);
    }

    /**
     * @notice [CUSTODIAL] Brand initiate dispute.
     */
    function initiateDispute(
        string memory _dealId,
        address _brandAddress,
        string memory _reason
    )
        external
        onlyOwner // RESTRICTED: onlyOwner
        whenNotPaused
        dealExists(_dealId)
        onlyDealBrand(_dealId, _brandAddress)
        inStatus(_dealId, ContractStatus.PENDING_REVIEW)
    {
        Deal storage deal = deals[_dealId];
        require(block.timestamp < deal.reviewDeadline, "Review period ended");
        require(bytes(_reason).length != 0, "Reason required"); // FIXED: Cheaper Conditional

        deal.status = ContractStatus.DISPUTED;

        emit DisputeInitiated(_dealId, _brandAddress, _reason);
    }

    /**
     * @notice [CUSTODIAL] Creator resolve dispute.
     */
    function resolveDispute(
        string memory _dealId,
        address _creatorAddress,
        bool _accept8020
    )
        external
        nonReentrant // FIXED: Pindahkan nonReentrant ke posisi awal
        onlyOwner // RESTRICTED: onlyOwner
        whenNotPaused
        dealExists(_dealId)
        onlyDealCreator(_dealId, _creatorAddress)
        inStatus(_dealId, ContractStatus.DISPUTED)
    {
        Deal storage deal = deals[_dealId];
        deal.status = ContractStatus.COMPLETED;

        uint256 totalEscrow = deal.amount;
        uint256 creatorAmount;
        uint256 brandRefund;
        uint256 platformFee;

        if (_accept8020) {
            // Logic Fee Deduction dari 80% Payout
            uint256 grossPayout = (totalEscrow * 8000) / BPS_DENOMINATOR;
            brandRefund = totalEscrow - grossPayout;

            // Hitung Fee dari 80% Gross Payout
            platformFee = (grossPayout * platformFeeBps) / BPS_DENOMINATOR;
            uint256 creatorNet = grossPayout - platformFee;

            creatorAmount = creatorNet;

            // Perform Transfers (SafeERC20)
            idrxToken.safeTransfer(deal.creator, creatorNet);
            idrxToken.safeTransfer(deal.brand, brandRefund);
            idrxToken.safeTransfer(feeRecipient, platformFee);
        } else {
            // 0% ke creator, 100% refund ke brand
            creatorAmount = 0;
            brandRefund = totalEscrow;
            platformFee = 0;

            // Perform Transfer (SafeERC20)
            idrxToken.safeTransfer(deal.brand, brandRefund);
        }

        emit DisputeResolved(
            _dealId,
            _creatorAddress,
            _accept8020,
            creatorAmount,
            brandRefund
        );
        emit PaymentReleased(_dealId, deal.creator, creatorAmount, platformFee);
    }

    /**
     * @notice Memicu refund penuh ke Brand jika Creator gagal submit konten sebelum deadline.
     * @dev Dapat dipanggil oleh Brand atau Server Wallet setelah deadline terlampaui dan status masih ACTIVE.
     */
    function autoRefundAfterDeadline(
        string memory _dealId
    )
        external
        nonReentrant
        whenNotPaused
        dealExists(_dealId)
        inStatus(_dealId, ContractStatus.ACTIVE) // Hanya berlaku jika deal masih ACTIVE (Creator belum submit)
    {
        Deal storage deal = deals[_dealId];

        require(
            block.timestamp > deal.deadline,
            "Deadline has not yet passed."
        );

        uint256 refundAmount = deal.amount;

        idrxToken.safeTransfer(deal.brand, refundAmount);

        deal.status = ContractStatus.CANCELLED;

        emit DealCancelled(_dealId, msg.sender, refundAmount); // msg.sender adalah yang memicu refund (Brand/Server)
    }

    /**
     * @notice [CUSTODIAL] Cancel deal sebelum funded.
     */
    function cancelDeal(
        string memory _dealId,
        address _brandAddress
    )
        external
        onlyOwner // RESTRICTED: onlyOwner
        dealExists(_dealId)
        onlyDealBrand(_dealId, _brandAddress)
        inStatus(_dealId, ContractStatus.PENDING)
    {
        Deal storage deal = deals[_dealId];
        deal.status = ContractStatus.CANCELLED;

        emit DealCancelled(_dealId, _brandAddress, 0);
    }

    /**
     * @notice Emergency cancel deal (owner only).
     */
    function emergencyCancelDeal(
        string memory _dealId
    )
        external
        nonReentrant // FIXED: Pindahkan nonReentrant ke posisi awal
        onlyOwner // RESTRICTED: onlyOwner
        dealExists(_dealId)
    {
        Deal storage deal = deals[_dealId];
        require(
            deal.status == ContractStatus.ACTIVE ||
                deal.status == ContractStatus.PENDING_REVIEW,
            "Cannot cancel this deal"
        );

        uint256 refundAmount = deal.amount;
        deal.status = ContractStatus.CANCELLED;

        // FIXED: Menggunakan SafeERC20
        idrxToken.safeTransfer(deal.brand, refundAmount);

        emit DealCancelled(_dealId, owner(), refundAmount);
    }

    // =================================================================
    // VIEW FUNCTIONS (GETTERS)
    // =================================================================

    /**
     * @notice Mendapatkan detail deal.
     */
    function getDeal(
        string memory _dealId
    )
        external
        view
        returns (
            string memory dealId,
            address brand,
            address creator,
            uint256 amount,
            uint256 deadline,
            ContractStatus status,
            string memory briefHash,
            string memory contentUrl,
            uint256 reviewDeadline,
            uint256 fundedAt,
            uint256 submittedAt,
            bool exists
        )
    {
        Deal storage deal = deals[_dealId];
        require(deal.exists, "Deal does not exist");

        return (
            deal.dealId,
            deal.brand,
            deal.creator,
            deal.amount,
            deal.deadline,
            deal.status,
            deal.briefHash,
            deal.contentUrl,
            deal.reviewDeadline,
            deal.fundedAt,
            deal.submittedAt,
            deal.exists
        );
    }

    /**
     * @notice Mendapatkan daftar deal berdasarkan Brand atau Creator.
     */
    function getDeals(
        address _userAddress,
        bool _isBrand
    ) external view returns (string[] memory) {
        if (_isBrand) {
            return brandDeals[_userAddress];
        } else {
            return creatorDeals[_userAddress];
        }
    }

    /**
     * @notice Check if can auto-release.
     */
    function canAutoRelease(
        string memory _dealId
    ) external view returns (bool) {
        Deal storage deal = deals[_dealId];
        return
            deal.exists &&
            deal.status == ContractStatus.PENDING_REVIEW &&
            block.timestamp >= deal.reviewDeadline;
    }

    // =================================================================
    // ADMIN FUNCTIONS
    // =================================================================

    /**
     * @notice Update platform fee (only owner).
     */
    function updatePlatformFee(uint256 _newFeeBps) external onlyOwner {
        require(_newFeeBps <= 1000, "Fee too high (max 10%)");

        uint256 oldFee = platformFeeBps;
        platformFeeBps = _newFeeBps;

        emit PlatformFeeUpdated(oldFee, _newFeeBps);
    }

    /**
     * @notice Update fee recipient (only owner).
     */
    function updateFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid address");
        address oldRecipient = feeRecipient;
        feeRecipient = _newRecipient;

        emit FeeRecipientUpdated(oldRecipient, _newRecipient);
    }

    /**
     * @notice Pause contract (emergency).
     * @dev Memanggil fungsi internal _pause() dari Pausable.
     */
    function pause() external onlyOwner {
        // FIXED: Owner-controlled pause
        _pause();
    }

    /**
     * @notice Unpause contract.
     * @dev Memanggil fungsi internal _unpause() dari Pausable.
     */
    function unpause() external onlyOwner {
        // FIXED: Owner-controlled unpause
        _unpause();
    }

    /**
     * @notice Withdraw stuck tokens (emergency only, not deal funds).
     */
    function emergencyWithdraw(
        address _token,
        uint256 _amount
    ) external onlyOwner {
        require(_token != address(idrxToken), "Cannot withdraw IDRX");
        // FIXED: Menggunakan SafeERC20.safeTransfer
        IERC20(_token).safeTransfer(owner(), _amount);
    }
}
