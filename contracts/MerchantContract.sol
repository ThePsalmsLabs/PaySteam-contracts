// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

library ProductTypes {
    enum ProductType { SINGLE, BULK, GROUP_BUYING }
    enum PurchaseStatus { PENDING, COMPLETED, REFUNDED, EXPIRED }
    enum GroupBuyingStatus { ACTIVE, COMPLETED, EXPIRED, CANCELLED }
}


// Individual Merchant Contract
contract MerchantContract is Ownable, ReentrancyGuard, Pausable {
   

    struct Product {
        uint256 id;
        string name;
        string description;
        uint128 price; // Optimized to uint128
        uint128 stock; // Optimized to uint128
        ProductTypes.ProductType productType;
        uint32 minGroupSize; // Optimized to uint32
        uint32 maxGroupSize; // Optimized to uint32, max 1000
        uint256 groupBuyingDeadline;
        uint256 cashbackPercentage; // in basis points (100 = 1%)
        uint128 bonanzaPrize; // Optimized to uint128
        bool isActive;
        uint256 createdAt;
    }

    struct Purchase {
        uint256 id;
        uint256 productId;
        address buyer;
        uint128 quantity; // Optimized to uint128
        uint128 totalAmount; // Optimized to uint128
        uint256 purchaseTime;
        ProductTypes.PurchaseStatus status;
        bool reviewLeft;
    }

    struct GroupBuying {
        uint256 productId;
        uint128 totalContributed; // Optimized to uint128
        uint32 participantCount; // Optimized to uint32
        mapping(address => uint128) contributions; // Optimized to uint128
        mapping(address => uint128) allocatedShares; // Optimized to uint128
        address[] participants;
        ProductTypes.GroupBuyingStatus status;
        uint256 deadline;
        bool fundsDistributed;
    }

    struct Review {
        uint256 purchaseId;
        address reviewer;
        uint8 rating; // 1-5 stars
        string comment;
        uint256 reviewTime;
    }

    

    mapping(uint256 => Product) public products;
    mapping(uint256 => Purchase) public purchases;
    mapping(uint256 => GroupBuying) public groupBuyings;
    mapping(uint256 => Review[]) public productReviews;
    mapping(address => uint256[]) public userPurchases;

    address public immutable marketplace;
    uint256 public nextProductId = 1;
    uint256 public nextPurchaseId = 1;
    uint256 private randomNonce; // For improved bonanza randomness
    uint32 public constant MAX_GROUP_SIZE = 1000; // Limit group size for gas efficiency
    uint256 public constant MIN_GROUP_DURATION = 1 hours;
    uint256 public constant MAX_GROUP_DURATION = 30 days;

    event ProductCreated(uint256 indexed productId, string name, ProductTypes.ProductType productType);
    event ProductUpdated(uint256 indexed productId, string name, uint128 price);
    event StockAdded(uint256 indexed productId, uint128 amount);
    event PurchaseMade(uint256 indexed purchaseId, uint256 indexed productId, address indexed buyer, uint128 amount);
    event GroupBuyingJoined(uint256 indexed productId, address indexed participant, uint128 contribution);
    event GroupBuyingCompleted(uint256 indexed productId, uint128 totalAmount);
    event GroupBuyingCancelled(uint256 indexed productId);
    event GroupBuyingWithdrawn(uint256 indexed productId, address indexed participant, uint128 amount);
    event ReviewAdded(uint256 indexed productId, uint256 indexed purchaseId, address indexed reviewer, uint8 rating);
    event CashbackPaid(address indexed recipient, uint128 amount);
    event BonanzaWon(address indexed winner, uint128 prize, uint256 productId);
    event FundsWithdrawn(address , uint256);

    modifier validProduct(uint256 productId) {
        require(products[productId].isActive, "Product not active");
        _;
    }

    modifier validPurchase(uint256 purchaseId) {
        require(purchases[purchaseId].buyer == msg.sender, "Not your purchase");
        require(purchases[purchaseId].status == ProductTypes.PurchaseStatus.COMPLETED, "Purchase not completed");
        require(!purchases[purchaseId].reviewLeft, "Review already left");
        _;
    }

    constructor(address _owner, address _marketplace) {
        _transferOwnership(_owner);
        marketplace = _marketplace;
        _pause(); // Start paused for safety
    }

    // Product Management
    function createProduct(
        string memory name,
        string memory description,
        uint128 price,
        uint128 stock,
        ProductTypes.ProductType productType,
        uint32 minGroupSize,
        uint32 maxGroupSize,
        uint256 groupBuyingDuration,
        uint256 cashbackPercentage,
        uint128 bonanzaPrize
    ) external onlyOwner whenNotPaused {
        require(bytes(name).length > 0, "Name cannot be empty");
        require(price > 0, "Price must be greater than 0");
        require(cashbackPercentage <= 2000, "Cashback too high"); // Max 20%

        if (productType == ProductTypes.ProductType.GROUP_BUYING) {
            require(minGroupSize > 0 && maxGroupSize >= minGroupSize, "Invalid group size");
            require(maxGroupSize <= MAX_GROUP_SIZE, "Group size too large");
            require(groupBuyingDuration >= MIN_GROUP_DURATION && groupBuyingDuration <= MAX_GROUP_DURATION, "Invalid duration");
        }

        uint256 deadline = productType == ProductTypes.ProductType.GROUP_BUYING 
            ? block.timestamp+ groupBuyingDuration
            : 0;

        products[nextProductId] = Product({
            id: nextProductId,
            name: name,
            description: description,
            price: price,
            stock: stock,
            productType: productType,
            minGroupSize: minGroupSize,
            maxGroupSize: maxGroupSize,
            groupBuyingDeadline: deadline,
            cashbackPercentage: cashbackPercentage,
            bonanzaPrize: bonanzaPrize,
            isActive: true,
            createdAt: block.timestamp
        });

        if (productType == ProductTypes.ProductType.GROUP_BUYING) {
            groupBuyings[nextProductId].productId = nextProductId;
            groupBuyings[nextProductId].status = ProductTypes.GroupBuyingStatus.ACTIVE;
            groupBuyings[nextProductId].deadline = deadline;
        }

        emit ProductCreated(nextProductId, name, productType);
        nextProductId++;
    }

    // Purchase Functions
    function purchaseSingleProduct(uint256 productId, uint128 quantity) 
        external payable validProduct(productId) nonReentrant whenNotPaused {
        Product storage product = products[productId];
        require(product.productType == ProductTypes.ProductType.SINGLE, "Not a single product");
        require(quantity > 0 && quantity <= product.stock, "Invalid quantity");

        uint256 totalAmount = uint256(product.price)*  quantity;
        require(msg.value >= totalAmount, "Insufficient payment");

        uint256 fee = totalAmount * MerchantMarketplace(marketplace).marketplaceFee() /  10000;
        uint256 merchantAmount = totalAmount.sub(fee);

        // Transfer fee to marketplace
        (bool success, ) = marketplace.call{value: fee}("");
        require(success, "Fee transfer failed");

        // Update stock
        product.stock = product.stock.sub(quantity);

        // Create purchase record
        purchases[nextPurchaseId] = Purchase({
            id: nextPurchaseId,
            productId: productId,
            buyer: msg.sender,
            quantity: quantity,
            totalAmount: uint128(totalAmount),
            purchaseTime: block.timestamp,
            status: ProductTypes.PurchaseStatus.COMPLETED,
            reviewLeft: false
        });

        userPurchases[msg.sender].push(nextPurchaseId);

        // Handle cashback
        if (product.cashbackPercentage > 0) {
            uint256 cashback = merchantAmount* product.cashbackPercentage /  10000;
            (success, ) = msg.sender.call{value: cashback}("");
            require(success, "Cashback transfer failed");
            emit CashbackPaid(msg.sender, uint128(cashback));
        }

        // Handle bonanza
        _handleBonanza(productId, msg.sender);

        // Refund excess payment
        if (msg.value > totalAmount) {
            (success, ) = msg.sender.call{value: msg.value.sub(totalAmount)}("");
            require(success, "Refund transfer failed");
        }

        emit PurchaseMade(nextPurchaseId, productId, msg.sender, uint128(totalAmount));
        nextPurchaseId++;
    }

    function purchaseBulkProduct(uint256 productId, uint128 quantity) 
        external payable validProduct(productId) nonReentrant whenNotPaused {
        Product storage product = products[productId];
        require(product.productType == ProductTypes.ProductType.BULK, "Not a bulk product");
        require(quantity > 0 && quantity <= product.stock, "Invalid quantity");

        uint256 totalAmount = uint256(product.price)*  quantity;
        require(msg.value >= totalAmount, "Insufficient payment");

        uint256 fee = totalAmount*  MerchantMarketplace(marketplace).marketplaceFee() /  10000;
        uint256 merchantAmount = totalAmount.sub(fee);

        // Transfer fee to marketplace
        (bool success, ) = marketplace.call{value: fee}("");
        require(success, "Fee transfer failed");

        // Update stock
        product.stock = product.stock.sub(quantity);

        // Create purchase record
        purchases[nextPurchaseId] = Purchase({
            id: nextPurchaseId,
            productId: productId,
            buyer: msg.sender,
            quantity: quantity,
            totalAmount: uint128(totalAmount),
            purchaseTime: block.timestamp,
            status: ProductTypes.PurchaseStatus.COMPLETED,
            reviewLeft: false
        });

        userPurchases[msg.sender].push(nextPurchaseId);

        // Handle cashback
        if (product.cashbackPercentage > 0) {
            uint256 cashback = merchantAmount*  product.cashbackPercentage /  10000;
            (success, ) = msg.sender.call{value: cashback}("");
            require(success, "Cashback transfer failed");
            emit CashbackPaid(msg.sender, uint128(cashback));
        }

        // Handle bonanza
        _handleBonanza(productId, msg.sender);

        // Refund excess payment
        if (msg.value > totalAmount) {
            (success, ) = msg.sender.call{value: msg.value.sub(totalAmount)}("");
            require(success, "Refund transfer failed");
        }

        emit PurchaseMade(nextPurchaseId, productId, msg.sender, uint128(totalAmount));
        nextPurchaseId++;
    }

    function joinGroupBuying(uint256 productId, uint128 maxContribution) 
        external payable validProduct(productId) nonReentrant whenNotPaused {
        Product storage product = products[productId];
        require(product.productType == ProductTypes.ProductType.GROUP_BUYING, "Not a group buying product");

        GroupBuying storage groupBuy = groupBuyings[productId];
        require(groupBuy.status == ProductTypes.GroupBuyingStatus.ACTIVE, "Group buying not active");
        require(block.timestamp <= groupBuy.deadline, "Group buying expired");
        require(groupBuy.contributions[msg.sender] == 0, "Already participated");
        require(groupBuy.participantCount < product.maxGroupSize, "Group is full");
        require(msg.value > 0, "Must contribute something");

        uint128 contribution = uint128(msg.value) > maxContribution ? maxContribution : uint128(msg.value);
        if (uint256(groupBuy.totalContributed)+ contribution > product.price) {
            contribution = uint128(uint256(product.price).sub(groupBuy.totalContributed));
        }
        require(contribution > 0, "Contribution too low");

        groupBuy.contributions[msg.sender] = contribution;
        groupBuy.totalContributed = groupBuy.totalContributed+ contribution;
        groupBuy.participants.push(msg.sender);
        groupBuy.participantCount++;

        // Refund excess contribution
        if (msg.value > contribution) {
            (bool success, ) = msg.sender.call{value: msg.value.sub(contribution)}("");
            require(success, "Refund transfer failed");
        }

        emit GroupBuyingJoined(productId, msg.sender, contribution);

        // Check if group buying is completed
        if (groupBuy.participantCount >= product.minGroupSize && 
            groupBuy.totalContributed >= product.price) {
            _completeGroupBuying(productId);
        }
    }

    function withdrawGroupContribution(uint256 productId) external nonReentrant whenNotPaused {
        Product storage product = products[productId];
        require(product.productType == ProductTypes.ProductType.GROUP_BUYING, "Not a group buying product");

        GroupBuying storage groupBuy = groupBuyings[productId];
        require(groupBuy.status == ProductTypes.GroupBuyingStatus.ACTIVE, "Group buying not active");
        require(block.timestamp <= groupBuy.deadline, "Group buying expired");
        require(groupBuy.contributions[msg.sender] > 0, "No contribution");

        uint128 contribution = groupBuy.contributions[msg.sender];
        groupBuy.contributions[msg.sender] = 0;
        groupBuy.totalContributed = groupBuy.totalContributed.sub(contribution);
        groupBuy.participantCount--;

        // Remove participant
        for (uint256 i = 0; i < groupBuy.participants.length; i++) {
            if (groupBuy.participants[i] == msg.sender) {
                groupBuy.participants[i] = groupBuy.participants[groupBuy.participants.length - 1];
                groupBuy.participants.pop();
                break;
            }
        }

        (bool success, ) = msg.sender.call{value: contribution}("");
        require(success, "Refund transfer failed");
        emit GroupBuyingWithdrawn(productId, msg.sender, contribution);
    }

    function finalizeGroupBuying(uint256 productId) external whenNotPaused {
        Product storage product = products[productId];
        require(product.productType == ProductTypes.ProductType.GROUP_BUYING, "Not a group buying product");

        GroupBuying storage groupBuy = groupBuyings[productId];
        require(groupBuy.status == ProductTypes.GroupBuyingStatus.ACTIVE, "Not active");
        require(block.timestamp > groupBuy.deadline, "Still active");

        if (groupBuy.participantCount >= product.minGroupSize && 
            groupBuy.totalContributed >= product.price) {
            _completeGroupBuying(productId);
        } else {
            _cancelGroupBuying(productId);
        }
    }

    function _completeGroupBuying(uint256 productId) internal {
        Product storage product = products[productId];
        GroupBuying storage groupBuy = groupBuyings[productId];

        groupBuy.status = ProductTypes.GroupBuyingStatus.COMPLETED;

        uint256 fee = uint256(groupBuy.totalContributed)* MerchantMarketplace(marketplace).marketplaceFee() /  10000;
        uint256 merchantAmount = uint256(groupBuy.totalContributed).sub(fee);

        // Transfer fee to marketplace
        (bool success, ) = marketplace.call{value: fee}("");
        require(success, "Fee transfer failed");

        // Calculate shares for each participant
        uint128 totalShares = product.stock;
        for (uint256 i = 0; i < groupBuy.participants.length; i++) {
            address participant = groupBuy.participants[i];
            uint128 contribution = groupBuy.contributions[participant];
            uint128 shares = uint128(uint256(contribution)*  totalShares) /  groupBuy.totalContributed;
            groupBuy.allocatedShares[participant] = shares;

            // Create purchase record
            purchases[nextPurchaseId] = Purchase({
                id: nextPurchaseId,
                productId: productId,
                buyer: participant,
                quantity: shares,
                totalAmount: contribution,
                purchaseTime: block.timestamp,
                status: ProductTypes.PurchaseStatus.COMPLETED,
                reviewLeft: false
            });

            userPurchases[participant].push(nextPurchaseId);
            nextPurchaseId++;

            // Handle cashback
            if (product.cashbackPercentage > 0) {
                uint128 cashback = uint128(merchantAmount*  product.cashbackPercentage  /  10000
                    * contribution) /  groupBuy.totalContributed;
                (success, ) = participant.call{value: cashback}("");
                require(success, "Cashback transfer failed");
                emit CashbackPaid(participant, cashback);
            }

            // Handle bonanza
            _handleBonanza(productId, participant);
        }

        product.stock = 0; // All stock allocated
        emit GroupBuyingCompleted(productId, groupBuy.totalContributed);
    }

    function _cancelGroupBuying(uint256 productId) internal {
        GroupBuying storage groupBuy = groupBuyings[productId];
        require(address(this).balance >= groupBuy.totalContributed, "Insufficient balance");

        groupBuy.status = ProductTypes.GroupBuyingStatus.CANCELLED;

        // Refund all participants
        for (uint256 i = 0; i < groupBuy.participants.length; i++) {
            address participant = groupBuy.participants[i];
            uint128 contribution = groupBuy.contributions[participant];
            if (contribution > 0) {
                groupBuy.contributions[participant] = 0;
                (bool success, ) = participant.call{value: contribution}("");
                require(success, "Refund transfer failed");
            }
        }
        emit GroupBuyingCancelled(productId);
    }

    function _handleBonanza(uint256 productId, address buyer) internal {
        Product storage product = products[productId];
        if (product.bonanzaPrize > 0) {
            // Improved pseudo-randomness using nonce
            randomNonce++;
            uint256 random = uint256(keccak256(abi.encodePacked(
                blockhash(block.number - 1),
                block.timestamp,
                buyer,
                productId,
                randomNonce
            ))) % 100;
            if (random < 5) {
                (bool success, ) = buyer.call{value: product.bonanzaPrize}("");
                if (success) {
                    emit BonanzaWon(buyer, product.bonanzaPrize, productId);
                }
            }
        }
    }

    // Review System
    function addReview(uint256 purchaseId, uint8 rating, string memory comment) 
        external validPurchase(purchaseId) whenNotPaused {
        require(rating >= 1 && rating <= 5, "Rating must be 1-5");
        require(bytes(comment).length <= 500, "Comment too long");

        Purchase storage purchase = purchases[purchaseId];
        purchase.reviewLeft = true;

        Review memory newReview = Review({
            purchaseId: purchaseId,
            reviewer: msg.sender,
            rating: rating,
            comment: comment,
            reviewTime: block.timestamp
        });

        productReviews[purchase.productId].push(newReview);
        emit ReviewAdded(purchase.productId, purchaseId, msg.sender, rating);
    }

    function getAverageRating(uint256 productId) external view returns (uint256 average, uint256 count) {
        Review[] storage reviews = productReviews[productId];
        if (reviews.length == 0) return (0, 0);

        uint256 totalRating = 0;
        for (uint256 i = 0; i < reviews.length; i++) {
            totalRating = totalRating+ reviews[i].rating;
        }
        return (totalRating /  reviews.length, reviews.length);
    }

    // Admin Functions
    function withdrawFunds() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No funds to withdraw");
        (bool success, ) = owner().call{value: balance}("");
        require(success, "Transfer failed");
        emit FundsWithdrawn(owner(), balance);
    }

    function updateProduct(
        uint256 productId,
        string memory name,
        string memory description,
        uint128 price,
        uint256 cashbackPercentage,
        uint128 bonanzaPrize
    ) external onlyOwner whenNotPaused {
        require(products[productId].isActive, "Product not active");
        require(bytes(name).length > 0, "Name cannot be empty");
        require(price > 0, "Price must be greater than 0");
        require(cashbackPercentage <= 2000, "Cashback too high");

        Product storage product = products[productId];
        product.name = name;
        product.description = description;
        product.price = price;
        product.cashbackPercentage = cashbackPercentage;
        product.bonanzaPrize = bonanzaPrize;

        emit ProductUpdated(productId, name, price);
    }

    function deactivateProduct(uint256 productId) external onlyOwner {
        products[productId].isActive = false;
    }

    function addStock(uint256 productId, uint128 amount) external onlyOwner validProduct(productId) {
        products[productId].stock = products[productId].stock+ amount;
        emit StockAdded(productId, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // View Functions
    function getProduct(uint256 productId) external view returns (Product memory) {
        return products[productId];
    }

    function getProductReviews(uint256 productId) external view returns (Review[] memory) {
        return productReviews[productId];
    }

    function getUserPurchases(address user) external view returns (uint256[] memory) {
        return userPurchases[user];
    }

    function getGroupBuyingInfo(uint256 productId) external view returns (
        uint128 totalContributed,
        uint32 participantCount,
        address[] memory participants,
        ProductTypes.GroupBuyingStatus status,
        uint256 deadline
    ) {
        GroupBuying storage groupBuy = groupBuyings[productId];
        return (
            groupBuy.totalContributed,
            groupBuy.participantCount,
            groupBuy.participants,
            groupBuy.status,
            groupBuy.deadline
        );
    }

    function getUserContribution(uint256 productId, address user) external view returns (uint128) {
        return groupBuyings[productId].contributions[user];
    }

    function getUserAllocatedShares(uint256 productId, address user) external view returns (uint128) {
        return groupBuyings[productId].allocatedShares[user];
    }

    receive() external payable {}
}