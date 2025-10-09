// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title SponsorFiEscrow
 * @dev Escrow contract untuk sponsorship deals antara Brand dan Creator
 * @notice Menggunakan IDRX sebagai payment token (Indonesian Rupiah stablecoin)
 */
contract SponsorFiEscrow is ReentrancyGuard, Ownable, Pausable {
    
    // IDRX Token address (akan di-set saat deployment)
    IERC20 public idrxToken;
    
    // Platform fee dalam basis points (250 = 2.5%)
    uint256 public platformFeeBps = 250; // 2.5%
    uint256 public constant BPS_DENOMINATOR = 10000;
    
    // Platform fee recipient
    address public feeRecipient;
    
    // Enum untuk status contract
    enum ContractStatus {
        PENDING,        // 0: Baru dibuat, belum funded
        ACTIVE,         // 1: Sudah funded, creator bisa mulai kerja
        PENDING_REVIEW, // 2: Content submitted, menunggu brand review (72h)
        DISPUTED,       // 3: Brand dispute deliverable
        COMPLETED,      // 4: Payment released ke creator
        CANCELLED       // 5: Deal cancelled
    }
    
    // Struct untuk menyimpan detail deal
    struct Deal {
        string dealId;              // ID unik deal (e.g., "SPFI-001")
        address brand;              // Wallet address brand
        address creator;            // Wallet address creator
        uint256 amount;             // Jumlah IDRX (dalam wei, 18 decimals)
        uint256 deadline;           // Unix timestamp deadline posting
        string briefHash;           // IPFS hash dari brief document
        ContractStatus status;      // Status deal saat ini
        uint256 fundedAt;           // Timestamp kapan di-fund
        uint256 submittedAt;        // Timestamp kapan creator submit
        uint256 reviewDeadline;     // Timestamp deadline review (72h after submit)
        string contentUrl;          // URL konten yang di-submit creator
        bool exists;                // Flag untuk cek apakah deal exists
    }
    
    // Mapping dealId => Deal
    mapping(string => Deal) public deals;
    
    // Mapping address => array of dealIds (untuk query deals per user)
    mapping(address => string[]) public brandDeals;
    mapping(address => string[]) public creatorDeals;
    
    // Events
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
        uint256 amount,
        uint256 timestamp
    );
    
    event ContentSubmitted(
        string indexed dealId,
        address indexed creator,
        string contentUrl,
        uint256 timestamp,
        uint256 reviewDeadline
    );
    
    event DealApproved(
        string indexed dealId,
        address indexed brand,
        uint256 timestamp
    );
    
    event PaymentReleased(
        string indexed dealId,
        address indexed creator,
        uint256 amount,
        uint256 platformFee,
        uint256 timestamp
    );
    
    event DisputeInitiated(
        string indexed dealId,
        address indexed brand,
        string reason,
        uint256 timestamp
    );
    
    event DisputeResolved(
        string indexed dealId,
        address indexed creator,
        bool accepted8020,
        uint256 creatorAmount,
        uint256 brandRefund,
        uint256 timestamp
    );
    
    event DealCancelled(
        string indexed dealId,
        address indexed initiator,
        uint256 refundAmount,
        uint256 timestamp
    );
    
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    
    // Modifiers
    modifier onlyBrand(string memory _dealId) {
        require(deals[_dealId].brand == msg.sender, "Only brand can call this");
        _;
    }
    
    modifier onlyCreator(string memory _dealId) {
        require(deals[_dealId].creator == msg.sender, "Only creator can call this");
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
    
    /**
     * @dev Constructor
     * @param _idrxToken Address of IDRX token contract
     * @param _feeRecipient Address untuk terima platform fee
     */
    constructor(address _idrxToken, address _feeRecipient, address _initialOwner) Ownable (_initialOwner) {
        require(_idrxToken != address(0), "Invalid IDRX token address");
        require(_feeRecipient != address(0), "Invalid fee recipient");
        
        idrxToken = IERC20(_idrxToken);
        feeRecipient = _feeRecipient;
    }
    
    /**
     * @dev Buat deal baru
     * @param _dealId ID unik untuk deal
     * @param _creator Wallet address creator
     * @param _amount Jumlah IDRX (dalam wei)
     * @param _deadline Unix timestamp deadline
     * @param _briefHash IPFS hash dari brief
     */
    function createDeal(
        string memory _dealId,
        address _creator,
        uint256 _amount,
        uint256 _deadline,
        string memory _briefHash
    ) external whenNotPaused {
        require(!deals[_dealId].exists, "Deal ID already exists");
        require(_creator != address(0), "Invalid creator address");
        require(_creator != msg.sender, "Creator cannot be brand");
        require(_amount > 0, "Amount must be greater than 0");
        require(_deadline > block.timestamp, "Deadline must be in future");
        require(bytes(_briefHash).length > 0, "Brief hash required");
        
        deals[_dealId] = Deal({
            dealId: _dealId,
            brand: msg.sender,
            creator: _creator,
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
        
        brandDeals[msg.sender].push(_dealId);
        creatorDeals[_creator].push(_dealId);
        
        emit DealCreated(_dealId, msg.sender, _creator, _amount, _deadline);
    }
    
    /**
     * @dev Fund deal dengan IDRX
     * @param _dealId ID deal yang akan di-fund
     */
    function fundDeal(string memory _dealId) 
        external 
        whenNotPaused
        dealExists(_dealId)
        onlyBrand(_dealId)
        inStatus(_dealId, ContractStatus.PENDING)
        nonReentrant
    {
        Deal storage deal = deals[_dealId];
        
        // Transfer IDRX dari brand ke contract
        require(
            idrxToken.transferFrom(msg.sender, address(this), deal.amount),
            "IDRX transfer failed"
        );
        
        deal.status = ContractStatus.ACTIVE;
        deal.fundedAt = block.timestamp;
        
        emit DealFunded(_dealId, msg.sender, deal.amount, block.timestamp);
    }
    
    /**
     * @dev Creator submit konten (dengan URL)
     * @param _dealId ID deal
     * @param _contentUrl URL konten yang sudah live
     */
    function submitContent(string memory _dealId, string memory _contentUrl)
        external
        whenNotPaused
        dealExists(_dealId)
        onlyCreator(_dealId)
        inStatus(_dealId, ContractStatus.ACTIVE)
    {
        require(bytes(_contentUrl).length > 0, "Content URL required");
        
        Deal storage deal = deals[_dealId];
        
        deal.status = ContractStatus.PENDING_REVIEW;
        deal.submittedAt = block.timestamp;
        deal.reviewDeadline = block.timestamp + 72 hours;
        deal.contentUrl = _contentUrl;
        
        emit ContentSubmitted(
            _dealId,
            msg.sender,
            _contentUrl,
            block.timestamp,
            deal.reviewDeadline
        );
    }
    
    /**
     * @dev Brand approve content & release payment instantly
     * @param _dealId ID deal
     */
    function approveDeal(string memory _dealId)
        external
        whenNotPaused
        dealExists(_dealId)
        onlyBrand(_dealId)
        inStatus(_dealId, ContractStatus.PENDING_REVIEW)
        nonReentrant
    {
        emit DealApproved(_dealId, msg.sender, block.timestamp);
        _releasePayment(_dealId);
    }
    
    /**
     * @dev Auto-release payment setelah 72 jam (callable by anyone)
     * @param _dealId ID deal
     */
    function autoReleasePayment(string memory _dealId)
        external
        whenNotPaused
        dealExists(_dealId)
        inStatus(_dealId, ContractStatus.PENDING_REVIEW)
        nonReentrant
    {
        Deal storage deal = deals[_dealId];
        require(block.timestamp >= deal.reviewDeadline, "Review period not ended");
        
        _releasePayment(_dealId);
    }
    
    /**
     * @dev Internal function untuk release payment
     * @param _dealId ID deal
     */
    function _releasePayment(string memory _dealId) internal {
        Deal storage deal = deals[_dealId];
        
        uint256 platformFee = (deal.amount * platformFeeBps) / BPS_DENOMINATOR;
        uint256 creatorAmount = deal.amount - platformFee;
        
        deal.status = ContractStatus.COMPLETED;
        
        // Transfer ke creator
        require(
            idrxToken.transfer(deal.creator, creatorAmount),
            "Transfer to creator failed"
        );
        
        // Transfer platform fee
        require(
            idrxToken.transfer(feeRecipient, platformFee),
            "Transfer fee failed"
        );
        
        emit PaymentReleased(
            _dealId,
            deal.creator,
            creatorAmount,
            platformFee,
            block.timestamp
        );
    }
    
    /**
     * @dev Brand initiate dispute
     * @param _dealId ID deal
     * @param _reason Alasan dispute
     */
    function initiateDispute(string memory _dealId, string memory _reason)
        external
        whenNotPaused
        dealExists(_dealId)
        onlyBrand(_dealId)
        inStatus(_dealId, ContractStatus.PENDING_REVIEW)
    {
        Deal storage deal = deals[_dealId];
        require(block.timestamp < deal.reviewDeadline, "Review period ended");
        require(bytes(_reason).length > 0, "Reason required");
        
        deal.status = ContractStatus.DISPUTED;
        
        emit DisputeInitiated(_dealId, msg.sender, _reason, block.timestamp);
    }
    
    /**
     * @dev Creator resolve dispute
     * @param _dealId ID deal
     * @param _accept8020 true = accept 80/20, false = reject (brand gets 100%)
     */
    function resolveDispute(string memory _dealId, bool _accept8020)
        external
        whenNotPaused
        dealExists(_dealId)
        onlyCreator(_dealId)
        inStatus(_dealId, ContractStatus.DISPUTED)
        nonReentrant
    {
        Deal storage deal = deals[_dealId];
        deal.status = ContractStatus.COMPLETED;
        
        uint256 creatorAmount;
        uint256 brandRefund;
        
        if (_accept8020) {
            // 80% ke creator, 20% refund ke brand
            creatorAmount = (deal.amount * 8000) / BPS_DENOMINATOR; // 80%
            brandRefund = deal.amount - creatorAmount; // 20%
            
            require(
                idrxToken.transfer(deal.creator, creatorAmount),
                "Transfer to creator failed"
            );
            require(
                idrxToken.transfer(deal.brand, brandRefund),
                "Refund to brand failed"
            );
        } else {
            // 0% ke creator, 100% refund ke brand
            creatorAmount = 0;
            brandRefund = deal.amount;
            
            require(
                idrxToken.transfer(deal.brand, brandRefund),
                "Refund to brand failed"
            );
        }
        
        emit DisputeResolved(
            _dealId,
            msg.sender,
            _accept8020,
            creatorAmount,
            brandRefund,
            block.timestamp
        );
    }
    
    /**
     * @dev Cancel deal sebelum funded (hanya brand yang bisa)
     * @param _dealId ID deal
     */
    function cancelDeal(string memory _dealId)
        external
        dealExists(_dealId)
        onlyBrand(_dealId)
        inStatus(_dealId, ContractStatus.PENDING)
    {
        Deal storage deal = deals[_dealId];
        deal.status = ContractStatus.CANCELLED;
        
        emit DealCancelled(_dealId, msg.sender, 0, block.timestamp);
    }
    
    /**
     * @dev Emergency cancel deal yang sudah funded (hanya owner)
     * @param _dealId ID deal
     * @notice Hanya untuk emergency, refund penuh ke brand
     */
    function emergencyCancelDeal(string memory _dealId)
        external
        onlyOwner
        dealExists(_dealId)
        nonReentrant
    {
        Deal storage deal = deals[_dealId];
        require(
            deal.status == ContractStatus.ACTIVE || 
            deal.status == ContractStatus.PENDING_REVIEW,
            "Cannot cancel this deal"
        );
        
        uint256 refundAmount = deal.amount;
        deal.status = ContractStatus.CANCELLED;
        
        require(
            idrxToken.transfer(deal.brand, refundAmount),
            "Refund failed"
        );
        
        emit DealCancelled(_dealId, msg.sender, refundAmount, block.timestamp);
    }
    
    // View functions
    
    /**
     * @dev Get deal details
     */
    function getDeal(string memory _dealId) external view returns (
        address brand,
        address creator,
        uint256 amount,
        uint256 deadline,
        ContractStatus status,
        string memory briefHash,
        string memory contentUrl,
        uint256 reviewDeadline
    ) {
        Deal storage deal = deals[_dealId];
        require(deal.exists, "Deal does not exist");
        
        return (
            deal.brand,
            deal.creator,
            deal.amount,
            deal.deadline,
            deal.status,
            deal.briefHash,
            deal.contentUrl,
            deal.reviewDeadline
        );
    }
    
    /**
     * @dev Get deals by brand
     */
    function getDealsByBrand(address _brand) external view returns (string[] memory) {
        return brandDeals[_brand];
    }
    
    /**
     * @dev Get deals by creator
     */
    function getDealsByCreator(address _creator) external view returns (string[] memory) {
        return creatorDeals[_creator];
    }
    
    /**
     * @dev Check if can auto-release
     */
    function canAutoRelease(string memory _dealId) external view returns (bool) {
        Deal storage deal = deals[_dealId];
        return deal.exists &&
               deal.status == ContractStatus.PENDING_REVIEW &&
               block.timestamp >= deal.reviewDeadline;
    }
    
    // Admin functions
    
    /**
     * @dev Update platform fee (only owner)
     */
    function updatePlatformFee(uint256 _newFeeBps) external onlyOwner {
        require(_newFeeBps <= 1000, "Fee too high (max 10%)"); // Max 10%
        
        uint256 oldFee = platformFeeBps;
        platformFeeBps = _newFeeBps;
        
        emit PlatformFeeUpdated(oldFee, _newFeeBps);
    }
    
    /**
     * @dev Update fee recipient
     */
    function updateFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid address");
        
        address oldRecipient = feeRecipient;
        feeRecipient = _newRecipient;
        
        emit FeeRecipientUpdated(oldRecipient, _newRecipient);
    }
    
    /**
     * @dev Pause contract (emergency)
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause contract
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    /**
     * @dev Withdraw stuck tokens (emergency only, not deal funds)
     */
    function emergencyWithdraw(address _token, uint256 _amount) external onlyOwner {
        require(_token != address(idrxToken), "Cannot withdraw IDRX");
        IERC20(_token).transfer(owner(), _amount);
    }
}