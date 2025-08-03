// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./MerchantContract.sol";



// Main Marketplace Contract
contract MerchantMarketplace is Ownable, ReentrancyGuard, Pausable {
    

    struct MarketplaceListing {
        address merchantContract;
        uint256 productId;
        string productName;
        uint128 price; // Optimized to uint128
        ProductTypes.ProductType productType;
        bool isActive;
        uint256 listedAt;
    }

    mapping(uint256 => MarketplaceListing) public marketplaceListings;
    mapping(address => bool) public registeredMerchants;
    mapping(address => address[]) public merchantContracts;
    uint256[] public activeListingIds; // Track active listings for gas efficiency

    uint256 public nextListingId = 1;
    uint256 public marketplaceFee = 250; // 2.5% in basis points
    uint256 public constant MAX_FEE = 1000; // 10% max
    uint256 public constant TIMELOCK_DELAY = 1 days; // Timelock for fee changes
    uint256 public feeChangeProposed;
    uint256 public feeChangeTimestamp;

    event MerchantRegistered(address indexed merchant, address indexed merchantContract);
    event ProductListed(uint256 indexed listingId, address indexed merchantContract, uint256 indexed productId);
    event ProductDelisted(uint256 indexed listingId);
    event MarketplaceFeeProposed(uint256 newFee, uint256 timestamp);
    event MarketplaceFeeUpdated(uint256 newFee);
    event FundsWithdrawn(address indexed recipient, uint256 amount);

    modifier onlyRegisteredMerchant() {
        require(registeredMerchants[msg.sender], "Not a registered merchant");
        _;
    }

    constructor()Ownable(msg.sender)  {
        _pause(); // Start paused for safety
    }

    function registerMerchant() external whenNotPaused {
        require(!registeredMerchants[msg.sender], "Already registered");

        MerchantContract newMerchant = new MerchantContract(msg.sender, address(this));
        merchantContracts[msg.sender].push(address(newMerchant));
        registeredMerchants[msg.sender] = true;

        emit MerchantRegistered(msg.sender, address(newMerchant));
    }

    function listProduct(
        address merchantContract,
        uint256 productId,
        string memory productName,
        uint128 price,
        ProductTypes.ProductType productType
    ) external onlyRegisteredMerchant whenNotPaused {
        require(MerchantContract(payable(merchantContract)).owner() == msg.sender, "Not your merchant contract");
        require(bytes(productName).length > 0, "Name cannot be empty");
        require(price > 0, "Price must be greater than 0");

        marketplaceListings[nextListingId] = MarketplaceListing({
            merchantContract: merchantContract,
            productId: productId,
            productName: productName,
            price: price,
            productType: productType,
            isActive: true,
            listedAt: block.timestamp
        });

        activeListingIds.push(nextListingId);
        emit ProductListed(nextListingId, merchantContract, productId);
        nextListingId++;
    }

    function delistProduct(uint256 listingId) external whenNotPaused {
        MarketplaceListing storage listing = marketplaceListings[listingId];
        require(listing.isActive, "Product not active");
        require(MerchantContract(payable(listing.merchantContract)).owner() == msg.sender, "Not authorized");

        listing.isActive = false;
        _removeActiveListing(listingId);
        emit ProductDelisted(listingId);
    }

    function proposeMarketplaceFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "Fee too high");
        feeChangeProposed = _fee;
        feeChangeTimestamp = block.timestamp;
        emit MarketplaceFeeProposed(_fee, block.timestamp);
    }

    function confirmMarketplaceFee() external onlyOwner {
        require(feeChangeTimestamp > 0, "No fee change proposed");
        require(block.timestamp >= feeChangeTimestamp +TIMELOCK_DELAY, "Timelock not elapsed");
        marketplaceFee = feeChangeProposed;
        feeChangeTimestamp = 0;
        emit MarketplaceFeeUpdated(marketplaceFee);
    }

    function withdrawFunds() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        (bool success, ) = owner().call{value: balance}("");
        require(success, "Transfer failed");
        emit FundsWithdrawn(owner(), balance);
    }

    function getMarketplaceListings(uint256 offset, uint256 limit) 
        external view returns (MarketplaceListing[] memory) {
        require(limit <= 100, "Limit too high");


        if (offset >= activeListingIds.length) return new MarketplaceListing[](0);

        uint256 resultLength = activeListingIds.length - offset > limit ? limit : activeListingIds.length - offset;
        MarketplaceListing[] memory result = new MarketplaceListing[](resultLength);

        for (uint256 i = 0; i < resultLength; i++) {
            result[i] = marketplaceListings[activeListingIds[offset+i]];
        }

        return result;
    }

    function _removeActiveListing(uint256 listingId) internal {
        for (uint256 i = 0; i < activeListingIds.length; i++) {
            if (activeListingIds[i] == listingId) {
                activeListingIds[i] = activeListingIds[activeListingIds.length - 1];
                activeListingIds.pop();
                break;
            }
        }
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    receive() external payable {}
}