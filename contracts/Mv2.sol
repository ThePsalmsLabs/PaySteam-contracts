// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";


// Product Types Library
library ProductTypes {
    enum ProductType { SINGLE, BULK, GROUP_BUYING }
    enum PurchaseStatus { PENDING, COMPLETED, REFUNDED, EXPIRED }
    enum GroupBuyingStatus { ACTIVE, COMPLETED, EXPIRED, CANCELLED }
}

// Interface for marketplace interaction
interface IMerchantMarketplace {
    function marketplaceFee() external returns (uint256);
    function processMarketplaceFee(uint256 amount, address token) external;
}

// Interface for ecommerce protocol interaction
interface IEcommerceProtocol {
    function processPaymentCallback(
        bytes16 paymentId,
        address merchant,
        uint256 productId,
        address buyer,
        uint256 amount,
        address token
    ) external;
}

/**
 * @title EnhancedMerchantContract
 * @dev Enhanced merchant contract with full ecommerce protocol integration
 * Supports multiple payment methods, currencies, and advanced features
 */
contract EnhancedMerchantContract is Ownable, ReentrancyGuard, Pausable {
    
    
    // ============ STRUCTS ============
    
    struct Product {
        uint256 id;
        string name;
        string description;
        uint128 price;
        uint128 stock;
        ProductTypes.ProductType productType;
       
        uint256 cashbackPercentage; // in basis points (100 = 1%)
        bool isActive;
        uint256 createdAt;
        address preferredCurrency; // Preferred payment currency (address(0) for ETH) 
        
    }

    struct ProductGroup {
        uint256 id;
        uint32 minGroupSize;
        uint32 maxGroupSize;
        uint256 groupBuyingDeadline;
        uint128 bulkDiscountPercentage; // Bulk discount in basis points
        uint128 discountThreshold; // Minimum quantity for bulk discount
    }
    
    struct Purchase {
        uint256 id;
        uint256 productId;
        address buyer;
        uint128 quantity;
        uint128 totalAmount;
        // uint256 purchaseTime;
        ProductTypes.PurchaseStatus status;
        bool reviewLeft;
        bytes16 paymentId; // Link to payment protocol
        address paymentToken;
        uint128 cashbackReceived;
        bool isProtocolPayment; // Whether payment was made through protocol
    }
    
    struct GroupBuying {
        uint256 productId;
        uint128 totalContributed;
        uint32 participantCount;
        mapping(address => uint128) contributions;
        mapping(address => uint128) allocatedShares;
        mapping(address => bytes16) paymentIds; // Track protocol payment IDs
        address[] participants;
        ProductTypes.GroupBuyingStatus status;
        uint256 deadline;
        bool fundsDistributed;
        address contributionToken; // Token used for contributions
    }
    
    struct Review {
        uint256 purchaseId;
        address reviewer;
        uint8 rating; // 1-5 stars
        string comment;
        uint256 reviewTime;
        bool isVerifiedPurchase; // True if reviewer actually bought the product
    }
    
    struct PaymentMethod {
        address token; // address(0) for ETH
        bool isEnabled;
        uint128 exchangeRate; // Rate relative to preferred currency (in basis points)
        uint256 lastUpdated;
    }
    
    // ============ STATE VARIABLES ============
    
    // Protocol integration
    address public immutable ecommerceProtocol;
    address public immutable marketplace;
    
    // Core mappings
    mapping(uint256 => Product) public products;
    mapping (uint256 => ProductGroup) public  productGroups;
    mapping(uint256 => Purchase) public purchases;
    mapping(uint256 => GroupBuying) public groupBuyings;
    mapping(uint256 => Review[]) public productReviews;
    mapping(address => uint256[]) public userPurchases;
    mapping(bytes16 => bool) public processedPayments;
    mapping(address => PaymentMethod) public paymentMethods;
    
    // Supported tokens
    address[] public supportedTokens;
    
    // Counters
    uint256 public nextProductId = 1;
    uint256 public nextPurchaseId = 1;
    
    // Configuration
    uint32 public constant MAX_GROUP_SIZE = 1000;
    uint256 public constant MIN_GROUP_DURATION = 1 hours;
    uint256 public constant MAX_GROUP_DURATION = 30 days;
    uint256 public constant MAX_CASHBACK_PERCENTAGE = 2000; // 20%
    uint256 public constant MAX_BULK_DISCOUNT = 5000; // 50%
    
    // Revenue tracking
    uint256 public totalRevenue;
    mapping(address => uint256) public tokenRevenue;
    
    // ============ EVENTS ============
    
    event ProductCreated(
        uint256 indexed productId, 
        string name, 
        ProductTypes.ProductType productType,
        uint128 price,
        address preferredCurrency
    );
    event ProductUpdated(uint256 indexed productId, string name, uint128 price);
    event StockAdded(uint256 indexed productId, uint128 amount);
    event PurchaseMade(
        uint256 indexed purchaseId, 
        uint256 indexed productId, 
        address indexed buyer, 
        uint128 amount,
        address paymentToken,
        bytes16 paymentId
    );
    event GroupBuyingJoined(
        uint256 indexed productId, 
        address indexed participant, 
        uint128 contribution,
        bytes16 paymentId
    );
    event GroupBuyingCompleted(uint256 indexed productId, uint128 totalAmount);
    event GroupBuyingCancelled(uint256 indexed productId);
    event GroupBuyingWithdrawn(
        uint256 indexed productId, 
        address indexed participant, 
        uint128 amount
    );
    event ReviewAdded(
        uint256 indexed productId, 
        uint256 indexed purchaseId, 
        address indexed reviewer, 
        uint8 rating,
        bool isVerified
    );
    event CashbackPaid(address indexed recipient, uint128 amount, address token);
    event FundsWithdrawn(address indexed owner, uint256 amount, address token);
    event PaymentProcessedViaProtocol(
        bytes16 indexed paymentId, 
        uint256 indexed productId, 
        address indexed buyer,
        uint256 amount,
        address token
    );
    event PaymentMethodUpdated(address indexed token, bool enabled, uint128 exchangeRate);
    event BulkDiscountApplied(
        uint256 indexed productId, 
        address indexed buyer, 
        uint128 discount
    );
    
    // ============ MODIFIERS ============
    
    modifier validProduct(uint256 productId) {
        require(products[productId].isActive, "Product not active");
        _;
    }
    
    modifier validPurchase(uint256 purchaseId) {
        require(purchases[purchaseId].buyer == msg.sender, "Not your purchase");
        require(
            purchases[purchaseId].status == ProductTypes.PurchaseStatus.COMPLETED, 
            "Purchase not completed"
        );
        require(!purchases[purchaseId].reviewLeft, "Review already left");
        _;
    }
    
    modifier onlyProtocol() {
        require(msg.sender == ecommerceProtocol, "Only protocol can call");
        _;
    }
    
    modifier supportedToken(address token) {
        require(paymentMethods[token].isEnabled, "Token not supported");
        _;
    }
    
    // ============ CONSTRUCTOR ============
    
    constructor(
        address _owner,
        address _marketplace,
        address _ecommerceProtocol
    ) Ownable(_owner) {
        marketplace = _marketplace;
        ecommerceProtocol = _ecommerceProtocol;
        
        // Enable ETH payments by default
        paymentMethods[address(0)] = PaymentMethod({
            token: address(0),
            isEnabled: true,
            exchangeRate: 10000, // 1:1 ratio (100%)
            lastUpdated: block.timestamp
        });
    }
    
    // ============ PROTOCOL INTEGRATION ============
    
    /**
     * @dev Process payment from the ecommerce protocol
     * Called by the protocol when a payment is successfully processed
     */
    function processPaymentFromProtocol(
        uint256 productId,
        uint128 quantity,
        bytes16 paymentId,
        address paymentToken,
        uint256 paymentAmount,
        address buyer
    ) external onlyProtocol nonReentrant returns (bool) {
        require(!processedPayments[paymentId], "Payment already processed");
        require(products[productId].isActive, "Product not active");
        
        Product storage product = products[productId];
        
        if (product.productType == ProductTypes.ProductType.GROUP_BUYING) {
            return _processGroupBuyingPaymentFromProtocol(
                productId, quantity, paymentId, paymentToken, paymentAmount, buyer
            );
        } else {
            return _processSingleBulkPaymentFromProtocol(
                productId, quantity, paymentId, paymentToken, paymentAmount, buyer
            );
        }
    }
    
    function _processSingleBulkPaymentFromProtocol(
        uint256 productId,
        uint128 quantity,
        bytes16 paymentId,
        address paymentToken,
        uint256 paymentAmount,
        address buyer
    ) internal returns (bool) {
        Product storage product = products[productId];
        ProductGroup storage productGroup = productGroups[productId];
        require(quantity > 0 && quantity <= product.stock, "Invalid quantity");
        
        // Calculate expected amount with potential bulk discount
        uint256 baseAmount = uint256(product.price) * quantity;
        uint256 discount = 0;
        
        if (product.productType == ProductTypes.ProductType.BULK && 
            quantity >= productGroup.discountThreshold) {
            discount = baseAmount * productGroup.bulkDiscountPercentage / 10000;
            emit BulkDiscountApplied(productId, buyer, uint128(discount));
        }
        
        uint256 expectedAmount = baseAmount - discount;
        require(paymentAmount >= expectedAmount, "Insufficient payment");
        
        // Update stock
        product.stock = product.stock - quantity;
        
        // Create purchase record
        purchases[nextPurchaseId] = Purchase({
            id: nextPurchaseId,
            productId: productId,
            buyer: buyer,
            quantity: quantity,
            totalAmount: uint128(paymentAmount),
            // purchaseTime: block.timestamp,
            status: ProductTypes.PurchaseStatus.COMPLETED,
            reviewLeft: false,
            paymentId: paymentId,
            paymentToken: paymentToken,
            cashbackReceived: 0,
            isProtocolPayment: true
        });
        
        userPurchases[buyer].push(nextPurchaseId);
        processedPayments[paymentId] = true;
        
        // Handle cashback
        if (product.cashbackPercentage > 0) {
            uint128 cashback = uint128(paymentAmount * product.cashbackPercentage / 10000);
            _processCashback(buyer, cashback, paymentToken);
            purchases[nextPurchaseId].cashbackReceived = cashback;
        }
        
        // Update revenue tracking
        _updateRevenue(paymentAmount, paymentToken);
        
        emit PurchaseMade(nextPurchaseId, productId, buyer, uint128(paymentAmount), paymentToken, paymentId);
        emit PaymentProcessedViaProtocol(paymentId, productId, buyer, paymentAmount, paymentToken);
        
        nextPurchaseId++;
        return true;
    }
    
    function _processGroupBuyingPaymentFromProtocol(
        uint256 productId,
        uint128 quantity, // Not used for group buying, kept for interface compatibility
        bytes16 paymentId,
        address paymentToken,
        uint256 paymentAmount,
        address buyer
    ) internal returns (bool) {
        Product storage product = products[productId];
        ProductGroup storage productGroup = productGroups[productId];
        GroupBuying storage groupBuy = groupBuyings[productId];
        
        require(groupBuy.status == ProductTypes.GroupBuyingStatus.ACTIVE, "Group buying not active");
        require(block.timestamp <= groupBuy.deadline, "Group buying expired");
        require(groupBuy.contributions[buyer] == 0, "Already participated");
        require(groupBuy.participantCount < productGroup.maxGroupSize, "Group is full");
        require(paymentAmount > 0, "Must contribute something");
        
        // Set contribution token if first participant
        if (groupBuy.participantCount == 0) {
            groupBuy.contributionToken = paymentToken;
        } else {
            require(groupBuy.contributionToken == paymentToken, "Token mismatch");
        }
        
        uint128 contribution = uint128(paymentAmount);
        if (uint256(groupBuy.totalContributed) + contribution > product.price) {
            contribution = uint128(uint256(product.price) - groupBuy.totalContributed);
        }
        
        groupBuy.contributions[buyer] = contribution;
        groupBuy.paymentIds[buyer] = paymentId;
        groupBuy.totalContributed = groupBuy.totalContributed + contribution;
        groupBuy.participants.push(buyer);
        groupBuy.participantCount++;
        
        processedPayments[paymentId] = true;
        _updateRevenue(contribution, paymentToken);
        
        emit GroupBuyingJoined(productId, buyer, contribution, paymentId);
        emit PaymentProcessedViaProtocol(paymentId, productId, buyer, contribution, paymentToken);
        
        // Check if group buying is completed
        if (groupBuy.participantCount >= productGroup.minGroupSize && 
            groupBuy.totalContributed >= product.price) {
            _completeGroupBuying(productId);
        }
        
        return true;
    }
    
    // ============ PRODUCT MANAGEMENT ============
    
    function createProduct(
        string memory name,
        // string memory description,
        uint128 price,
        uint128 stock,
        ProductTypes.ProductType productType,
        uint32 minGroupSize,
        uint32 maxGroupSize,
        uint256 groupBuyingDuration,
        uint256 cashbackPercentage,
        address preferredCurrency,
        uint128 discountThreshold,
        uint128 bulkDiscountPercentage
    ) external onlyOwner whenNotPaused {
        require(bytes(name).length > 0, "Name cannot be empty");
        require(price > 0, "Price must be greater than 0");
        require(cashbackPercentage <= MAX_CASHBACK_PERCENTAGE, "Cashback too high");
        require(bulkDiscountPercentage <= MAX_BULK_DISCOUNT, "Bulk discount too high");
        
        if (productType == ProductTypes.ProductType.GROUP_BUYING) {
            require(minGroupSize > 0 && maxGroupSize >= minGroupSize, "Invalid group size");
            require(maxGroupSize <= MAX_GROUP_SIZE, "Group size too large");
            require(
                groupBuyingDuration >= MIN_GROUP_DURATION && 
                groupBuyingDuration <= MAX_GROUP_DURATION, 
                "Invalid duration"
            );
        }
        
        uint256 deadline = productType == ProductTypes.ProductType.GROUP_BUYING 
            ? block.timestamp + groupBuyingDuration
            : 0;
        
        products[nextProductId] = Product({
            id: nextProductId,
            name: name,
            description: "",
            price: price,
            stock: stock,
            productType: productType,
          
            cashbackPercentage: cashbackPercentage,
            isActive: true,
            createdAt: block.timestamp,
            preferredCurrency: preferredCurrency
            
        });

        productGroups[nextProductId] = ProductGroup({
             id: nextProductId,
             minGroupSize: minGroupSize,
            maxGroupSize: maxGroupSize,
            groupBuyingDeadline: deadline,
            discountThreshold: discountThreshold,
            bulkDiscountPercentage: bulkDiscountPercentage
        });
        
        if (productType == ProductTypes.ProductType.GROUP_BUYING) {
            groupBuyings[nextProductId].productId = nextProductId;
            groupBuyings[nextProductId].status = ProductTypes.GroupBuyingStatus.ACTIVE;
            groupBuyings[nextProductId].deadline = deadline;
        }
        
        emit ProductCreated(nextProductId, name, productType, price, preferredCurrency);
        nextProductId++;
    }
    
    // function updateProduct(
    //     uint256 productId,
    //     string memory name,
    //     string memory description,
    //     uint128 price,
    //     uint256 cashbackPercentage,
    //     uint128 discountThreshold,
    //     uint128 bulkDiscountPercentage
    // ) external onlyOwner whenNotPaused {
    //     require(products[productId].isActive, "Product not active");
    //     require(bytes(name).length > 0, "Name cannot be empty");
    //     require(price > 0, "Price must be greater than 0");
    //     require(cashbackPercentage <= MAX_CASHBACK_PERCENTAGE, "Cashback too high");
    //     require(bulkDiscountPercentage <= MAX_BULK_DISCOUNT, "Bulk discount too high");
        
    //     Product storage product = products[productId];
    //     ProductGroup storage productGroup = productGroups[productId];
    //     product.name = name;
    //     product.description = description;
    //     product.price = price;
    //     product.cashbackPercentage = cashbackPercentage;
    //     productGroup.discountThreshold = discountThreshold;
    //     productGroup.bulkDiscountPercentage = bulkDiscountPercentage;
        
    //     emit ProductUpdated(productId, name, price);
    // }
    
    // function deactivateProduct(uint256 productId) external onlyOwner {
    //     products[productId].isActive = false;
    // }
    
    // function addStock(uint256 productId, uint128 amount) external onlyOwner validProduct(productId) {
    //     products[productId].stock = products[productId].stock + amount;
    //     emit StockAdded(productId, amount);
    // }
    
    // ============ PAYMENT METHOD MANAGEMENT ============
    
    // function addPaymentMethod(
    //     address token,
    //     uint128 exchangeRate
    // ) external onlyOwner {
    //     require(token != address(0), "Use updatePaymentMethod for ETH");
    //     require(exchangeRate > 0, "Invalid exchange rate");
        
    //     if (!paymentMethods[token].isEnabled) {
    //         supportedTokens.push(token);
    //     }
        
    //     paymentMethods[token] = PaymentMethod({
    //         token: token,
    //         isEnabled: true,
    //         exchangeRate: exchangeRate,
    //         lastUpdated: block.timestamp
    //     });
        
    //     emit PaymentMethodUpdated(token, true, exchangeRate);
    // }
    
    // function updatePaymentMethod(
    //     address token,
    //     bool enabled,
    //     uint128 exchangeRate
    // ) external onlyOwner {
    //     require(exchangeRate > 0 || !enabled, "Invalid exchange rate");
        
    //     paymentMethods[token].isEnabled = enabled;
    //     paymentMethods[token].exchangeRate = exchangeRate;
    //     paymentMethods[token].lastUpdated = block.timestamp;
        
    //     emit PaymentMethodUpdated(token, enabled, exchangeRate);
    // }
    
    // ============ DIRECT PURCHASE FUNCTIONS (Legacy Support) ============
    
    // function purchaseSingleProduct(
    //     uint256 productId, 
    //     uint128 quantity
    // ) external payable validProduct(productId) nonReentrant whenNotPaused {
    //     Product storage product = products[productId];
    //     require(product.productType == ProductTypes.ProductType.SINGLE, "Not a single product");
    //     require(quantity > 0 && quantity <= product.stock, "Invalid quantity");
        
    //     uint256 totalAmount = uint256(product.price) * quantity;
    //     require(msg.value >= totalAmount, "Insufficient payment");
        
    //     _processDirectPurchase(productId, quantity, totalAmount, address(0));
        
    //     // Refund excess payment
    //     if (msg.value > totalAmount) {
    //         (bool success,) = msg.sender.call{value: msg.value - totalAmount}("");
    //         require(success, "Refund transfer failed");
    //     }
    // }
    
    // function purchaseBulkProduct(
    //     uint256 productId, 
    //     uint128 quantity
    // ) external payable validProduct(productId) nonReentrant whenNotPaused {
    //     Product storage product = products[productId];
    //     ProductGroup storage productGroup = productGroups[productId];
    //     require(product.productType == ProductTypes.ProductType.BULK, "Not a bulk product");
    //     require(quantity > 0 && quantity <= product.stock, "Invalid quantity");
        
    //     uint256 baseAmount = uint256(product.price) * quantity;
    //     uint256 discount = 0;
        
    //     if (quantity >= productGroup.discountThreshold) {
    //         discount = baseAmount * productGroup.bulkDiscountPercentage / 10000;
    //         emit BulkDiscountApplied(productId, msg.sender, uint128(discount));
    //     }
        
    //     uint256 totalAmount = baseAmount - discount;
    //     require(msg.value >= totalAmount, "Insufficient payment");
        
    //     _processDirectPurchase(productId, quantity, totalAmount, address(0));
        
    //     // Refund excess payment
    //     if (msg.value > totalAmount) {
    //         (bool success,) = msg.sender.call{value: msg.value - totalAmount}("");
    //         require(success, "Refund transfer failed");
    //     }
    // }
    
    // function _processDirectPurchase(
    //     uint256 productId,
    //     uint128 quantity,
    //     uint256 totalAmount,
    //     address paymentToken
    // ) internal {
    //     Product storage product = products[productId];
        
    //     // Calculate marketplace fee
    //     uint256 fee = totalAmount * IMerchantMarketplace(marketplace).marketplaceFee() / 10000;
    //     uint256 merchantAmount = totalAmount - fee;
        
    //     // Transfer fee to marketplace (for ETH payments)
    //     if (paymentToken == address(0)) {
    //         (bool success,) = marketplace.call{value: fee}("");
    //         require(success, "Fee transfer failed");
    //     }
        
    //     // Update stock
    //     product.stock = product.stock - quantity;
        
    //     // Create purchase record
    //     purchases[nextPurchaseId] = Purchase({
    //         id: nextPurchaseId,
    //         productId: productId,
    //         buyer: msg.sender,
    //         quantity: quantity,
    //         totalAmount: uint128(totalAmount),
    //         // purchaseTime: block.timestamp,
    //         status: ProductTypes.PurchaseStatus.COMPLETED,
    //         reviewLeft: false,
    //         paymentId: bytes16(0), // No protocol payment ID for direct purchases
    //         paymentToken: paymentToken,
    //         cashbackReceived: 0,
    //         isProtocolPayment: false
    //     });
        
    //     userPurchases[msg.sender].push(nextPurchaseId);
        
    //     // Handle cashback
    //     if (product.cashbackPercentage > 0) {
    //         uint128 cashback = uint128(merchantAmount * product.cashbackPercentage / 10000);
    //         _processCashback(msg.sender, cashback, paymentToken);
    //         purchases[nextPurchaseId].cashbackReceived = cashback;
    //     }
        
    //     // Update revenue tracking
    //     _updateRevenue(totalAmount, paymentToken);
        
    //     emit PurchaseMade(nextPurchaseId, productId, msg.sender, uint128(totalAmount), paymentToken, bytes16(0));
    //     nextPurchaseId++;
    // }
    
    // ============ GROUP BUYING FUNCTIONS ============
    
    // function joinGroupBuying(
    //     uint256 productId, 
    //     uint128 maxContribution
    // ) external payable validProduct(productId) nonReentrant whenNotPaused {
    //     Product storage product = products[productId];
    //     ProductGroup storage productGroup = productGroups[productId];
    //     require(product.productType == ProductTypes.ProductType.GROUP_BUYING, "Not a group buying product");
        
    //     GroupBuying storage groupBuy = groupBuyings[productId];
    //     require(groupBuy.status == ProductTypes.GroupBuyingStatus.ACTIVE, "Group buying not active");
    //     require(block.timestamp <= groupBuy.deadline, "Group buying expired");
    //     require(groupBuy.contributions[msg.sender] == 0, "Already participated");
    //     require(groupBuy.participantCount < productGroup.maxGroupSize, "Group is full");
    //     require(msg.value > 0, "Must contribute something");
        
    //     // Set contribution token if first participant
    //     if (groupBuy.participantCount == 0) {
    //         groupBuy.contributionToken = address(0); // ETH
    //     } else {
    //         require(groupBuy.contributionToken == address(0), "Token mismatch");
    //     }
        
    //     uint128 contribution = uint128(msg.value) > maxContribution ? maxContribution : uint128(msg.value);
    //     if (uint256(groupBuy.totalContributed) + contribution > product.price) {
    //         contribution = uint128(uint256(product.price) - groupBuy.totalContributed);
    //     }
    //     require(contribution > 0, "Contribution too low");
        
    //     groupBuy.contributions[msg.sender] = contribution;
    //     groupBuy.totalContributed = groupBuy.totalContributed + contribution;
    //     groupBuy.participants.push(msg.sender);
    //     groupBuy.participantCount++;
        
    //     // Update revenue tracking
    //     _updateRevenue(contribution, address(0));
        
    //     // Refund excess contribution
    //     if (msg.value > contribution) {
    //         (bool success,) = msg.sender.call{value: msg.value - contribution}("");
    //         require(success, "Refund transfer failed");
    //     }
        
    //     emit GroupBuyingJoined(productId, msg.sender, contribution, bytes16(0));
        
    //     // Check if group buying is completed
    //     if (groupBuy.participantCount >= productGroup.minGroupSize && 
    //         groupBuy.totalContributed >= product.price) {
    //         _completeGroupBuying(productId);
    //     }
    // }
    
    // function withdrawGroupContribution(uint256 productId) external nonReentrant whenNotPaused {
    //     Product storage product = products[productId];
    //     require(product.productType == ProductTypes.ProductType.GROUP_BUYING, "Not a group buying product");
        
    //     GroupBuying storage groupBuy = groupBuyings[productId];
    //     require(groupBuy.status == ProductTypes.GroupBuyingStatus.ACTIVE, "Group buying not active");
    //     require(block.timestamp <= groupBuy.deadline, "Group buying expired");
    //     require(groupBuy.contributions[msg.sender] > 0, "No contribution");
        
    //     uint128 contribution = groupBuy.contributions[msg.sender];
    //     groupBuy.contributions[msg.sender] = 0;
    //     groupBuy.totalContributed = groupBuy.totalContributed - contribution;
    //     groupBuy.participantCount--;
        
    //     // Remove participant from array
    //     for (uint256 i = 0; i < groupBuy.participants.length; i++) {
    //         if (groupBuy.participants[i] == msg.sender) {
    //             groupBuy.participants[i] = groupBuy.participants[groupBuy.participants.length - 1];
    //             groupBuy.participants.pop();
    //             break;
    //         }
    //     }
        
    //     // Update revenue tracking (subtract)
    //     tokenRevenue[groupBuy.contributionToken] -= contribution;
    //     totalRevenue -= contribution;
        
    //     // Process refund
    //     if (groupBuy.contributionToken == address(0)) {
    //         (bool success,) = msg.sender.call{value: contribution}("");
    //         require(success, "Refund transfer failed");
    //     } else {
    //         IERC20(groupBuy.contributionToken).transfer(msg.sender, contribution);
    //     }
        
    //     emit GroupBuyingWithdrawn(productId, msg.sender, contribution);
    // }
    
    // function finalizeGroupBuying(uint256 productId) external whenNotPaused {
    //     Product storage product = products[productId];
    //      ProductGroup storage productGroup = productGroups[productId];
    //     require(product.productType == ProductTypes.ProductType.GROUP_BUYING, "Not a group buying product");
        
    //     GroupBuying storage groupBuy = groupBuyings[productId];
    //     require(groupBuy.status == ProductTypes.GroupBuyingStatus.ACTIVE, "Not active");
    //     require(block.timestamp > groupBuy.deadline, "Still active");
        
    //     if (groupBuy.participantCount >= productGroup.minGroupSize && 
    //         groupBuy.totalContributed >= product.price) {
    //         _completeGroupBuying(productId);
    //     } else {
    //         _cancelGroupBuying(productId);
    //     }
    // }
    
    function _completeGroupBuying(uint256 productId) internal {
        Product storage product = products[productId];
        GroupBuying storage groupBuy = groupBuyings[productId];
        
        groupBuy.status = ProductTypes.GroupBuyingStatus.COMPLETED;
        
        // Calculate marketplace fee
        uint256 fee = uint256(groupBuy.totalContributed) * IMerchantMarketplace(marketplace).marketplaceFee() / 10000;
        uint256 merchantAmount = uint256(groupBuy.totalContributed) - fee;
        
        // Transfer fee to marketplace
        if (groupBuy.contributionToken == address(0)) {
            (bool success,) = marketplace.call{value: fee}("");
            require(success, "Fee transfer failed");
        } else {
            IERC20(groupBuy.contributionToken).transfer(marketplace, fee);
        }
        
        // Calculate shares for each participant
        uint128 totalShares = product.stock;
        for (uint256 i = 0; i < groupBuy.participants.length; i++) {
            address participant = groupBuy.participants[i];
            uint128 contribution = groupBuy.contributions[participant];
            uint128 shares = uint128(uint256(contribution) * totalShares / groupBuy.totalContributed);
            groupBuy.allocatedShares[participant] = shares;
            
            // Create purchase record
            purchases[nextPurchaseId] = Purchase({
                id: nextPurchaseId,
                productId: productId,
                buyer: participant,
                quantity: shares,
                totalAmount: contribution,
                // purchaseTime: block.timestamp,
                status: ProductTypes.PurchaseStatus.COMPLETED,
                reviewLeft: false,
                paymentId: groupBuy.paymentIds[participant],
                paymentToken: groupBuy.contributionToken,
                cashbackReceived: 0,
                isProtocolPayment: groupBuy.paymentIds[participant] != bytes16(0)
            });
            
            userPurchases[participant].push(nextPurchaseId);
            
            // Handle cashback
            if (product.cashbackPercentage > 0) {
                uint128 participantMerchantAmount = uint128(merchantAmount * contribution / groupBuy.totalContributed);
                uint128 cashback = uint128(participantMerchantAmount * product.cashbackPercentage / 10000);
                _processCashback(participant, cashback, groupBuy.contributionToken);
                purchases[nextPurchaseId].cashbackReceived = cashback;
            }
            
            nextPurchaseId++;
        }
        
        product.stock = 0; // All stock allocated
        emit GroupBuyingCompleted(productId, groupBuy.totalContributed);
    }
    
    function _cancelGroupBuying(uint256 productId) internal {
        GroupBuying storage groupBuy = groupBuyings[productId];
        groupBuy.status = ProductTypes.GroupBuyingStatus.CANCELLED;
        
        // Refund all participants
        for (uint256 i = 0; i < groupBuy.participants.length; i++) {
            address participant = groupBuy.participants[i];
            uint128 contribution = groupBuy.contributions[participant];
            if (contribution > 0) {
                groupBuy.contributions[participant] = 0;
                
                // Update revenue tracking (subtract)
                tokenRevenue[groupBuy.contributionToken] -= contribution;
                totalRevenue -= contribution;
                
                // Process refund
                if (groupBuy.contributionToken == address(0)) {
                    (bool success,) = participant.call{value: contribution}("");
                    require(success, "Refund transfer failed");
                } else {
                    IERC20(groupBuy.contributionToken).transfer(participant, contribution);
                }
            }
        }
        emit GroupBuyingCancelled(productId);
    }
    
    // ============ REVIEW SYSTEM ============
    
    // function addReview(
    //     uint256 purchaseId, 
    //     uint8 rating, 
    //     string memory comment
    // ) external validPurchase(purchaseId) whenNotPaused {
    //     require(rating >= 1 && rating <= 5, "Rating must be 1-5");
    //     require(bytes(comment).length <= 500, "Comment too long");
        
    //     Purchase storage purchase = purchases[purchaseId];
    //     purchase.reviewLeft = true;
        
    //     Review memory newReview = Review({
    //         purchaseId: purchaseId,
    //         reviewer: msg.sender,
    //         rating: rating,
    //         comment: comment,
    //         reviewTime: block.timestamp,
    //         isVerifiedPurchase: true // Always true since we validate the purchase
    //     });
        
    //     productReviews[purchase.productId].push(newReview);
    //     emit ReviewAdded(purchase.productId, purchaseId, msg.sender, rating, true);
    // }
    
    // function getAverageRating(uint256 productId) external view returns (uint256 average, uint256 count) {
    //     Review[] storage reviews = productReviews[productId];
    //     if (reviews.length == 0) return (0, 0);
        
    //     uint256 totalRating = 0;
    //     uint256 verifiedCount = 0;
        
    //     for (uint256 i = 0; i < reviews.length; i++) {
    //         if (reviews[i].isVerifiedPurchase) {
    //             totalRating += reviews[i].rating;
    //             verifiedCount++;
    //         }
    //     }
        
    //     if (verifiedCount == 0) return (0, 0);
    //     return (totalRating / verifiedCount, verifiedCount);
    // }
    
    // function getProductReviews(uint256 productId) external view returns (Review[] memory) {
    //     return productReviews[productId];
    // }
    
    // ============ INTERNAL HELPER FUNCTIONS ============
    
    function _processCashback(address recipient, uint128 amount, address token) internal {
        if (amount == 0) return;
        
        if (token == address(0)) {
            // ETH cashback
            if (address(this).balance >= amount) {
                (bool success,) = recipient.call{value: amount}("");
                if (success) {
                    emit CashbackPaid(recipient, amount, token);
                }
            }
        } else {
            // Token cashback
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance >= amount) {
                IERC20(token).transfer(recipient, amount);
                emit CashbackPaid(recipient, amount, token);
            }
        }
    }
    
    function _updateRevenue(uint256 amount, address token) internal {
        totalRevenue += amount;
        tokenRevenue[token] += amount;
    }
    
    // ============ ADMIN FUNCTIONS ============
    
    // function withdrawFunds(address token, uint256 amount) external onlyOwner nonReentrant {
    //     if (token == address(0)) {
    //         // Withdraw ETH
    //         if (amount == 0) amount = address(this).balance;
    //         require(amount > 0, "No ETH to withdraw");
    //         require(address(this).balance >= amount, "Insufficient ETH balance");
            
    //         (bool success,) = owner().call{value: amount}("");
    //         require(success, "ETH transfer failed");
    //     } else {
    //         // Withdraw tokens
    //         IERC20 tokenContract = IERC20(token);
    //         if (amount == 0) amount = tokenContract.balanceOf(address(this));
    //         require(amount > 0, "No tokens to withdraw");
            
    //         tokenContract.transfer(owner(), amount);
    //     }
        
    //     emit FundsWithdrawn(owner(), amount, token);
    // }
    
    // function emergencyWithdraw(address token) external onlyOwner {
    //     if (token == address(0)) {
    //         uint256 balance = address(this).balance;
    //         if (balance > 0) {
    //             (bool success,) = owner().call{value: balance}("");
    //             require(success, "Emergency ETH withdrawal failed");
    //         }
    //     } else {
    //         IERC20 tokenContract = IERC20(token);
    //         uint256 balance = tokenContract.balanceOf(address(this));
    //         if (balance > 0) {
    //             tokenContract.transfer(owner(), balance);
    //         }
    //     }
    // }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ============ VIEW FUNCTIONS ============
    
    // function getProduct(uint256 productId) external view returns (Product memory) {
    //     return products[productId];
    // }
    
    // function getPurchase(uint256 purchaseId) external view returns (Purchase memory) {
    //     return purchases[purchaseId];
    // }
    
    // function getUserPurchases(address user) external view returns (uint256[] memory) {
    //     return userPurchases[user];
    // }
    
    function getGroupBuyingInfo(uint256 productId) external view returns (
        uint128 totalContributed,
        uint32 participantCount,
        address[] memory participants,
        ProductTypes.GroupBuyingStatus status,
        uint256 deadline,
        address contributionToken
    ) {
        GroupBuying storage groupBuy = groupBuyings[productId];
        return (
            groupBuy.totalContributed,
            groupBuy.participantCount,
            groupBuy.participants,
            groupBuy.status,
            groupBuy.deadline,
            groupBuy.contributionToken
        );
    }
    
    // function getUserContribution(uint256 productId, address user) external view returns (uint128) {
    //     return groupBuyings[productId].contributions[user];
    // }
    
    // function getUserAllocatedShares(uint256 productId, address user) external view returns (uint128) {
    //     return groupBuyings[productId].allocatedShares[user];
    // }
    
    // function getUserPaymentId(uint256 productId, address user) external view returns (bytes16) {
    //     return groupBuyings[productId].paymentIds[user];
    // }
    
    // function getSupportedTokens() external view returns (address[] memory) {
    //     return supportedTokens;
    // }
    
    // function getPaymentMethod(address token) external view returns (PaymentMethod memory) {
    //     return paymentMethods[token];
    // }
    
    // function getRevenue() external view returns (uint256 total, uint256 eth) {
    //     return (totalRevenue, tokenRevenue[address(0)]);
    // }
    
    // function getTokenRevenue(address token) external view returns (uint256) {
    //     return tokenRevenue[token];
    // }
    
    // function calculatePrice(
    //     uint256 productId, 
    //     uint128 quantity
    // ) external view returns (uint256 basePrice, uint256 discount, uint256 finalPrice) {
    //     Product storage product = products[productId];
    //     ProductGroup storage productGroup = productGroups[productId];
    //     require(product.isActive, "Product not active");
        
    //     basePrice = uint256(product.price) * quantity;
    //     discount = 0;
        
    //     if (product.productType == ProductTypes.ProductType.BULK && 
    //         quantity >= productGroup.discountThreshold) {
    //         discount = basePrice * productGroup.bulkDiscountPercentage / 10000;
    //     }
        
    //     finalPrice = basePrice - discount;
    // }
    
    function calculateCashback(
        uint256 productId, 
        uint256 amount
    ) external returns (uint256) {
        Product storage product = products[productId];
        if (product.cashbackPercentage == 0) return 0;
        
        // Calculate cashback on merchant amount (after marketplace fee)
        uint256 fee = amount * IMerchantMarketplace(marketplace).marketplaceFee() / 10000;
        uint256 merchantAmount = amount - fee;
        return merchantAmount * product.cashbackPercentage / 10000;
    }
    
    // function isProductActive(uint256 productId) external view returns (bool) {
    //     return products[productId].isActive;
    // }
    
    // function getProductStock(uint256 productId) external view returns (uint128) {
    //     return products[productId].stock;
    // }
    
    function canPurchase(
        uint256 productId, 
        uint128 quantity, 
        address buyer
    ) external view returns (bool canPurchase_, string memory reason) {
        Product storage product = products[productId];
         ProductGroup storage productGroup = productGroups[productId];
        
        if (!product.isActive) {
            return (false, "Product not active");
        }
        
        if (quantity == 0) {
            return (false, "Invalid quantity");
        }
        
        if (quantity > product.stock) {
            return (false, "Insufficient stock");
        }
        
        if (product.productType == ProductTypes.ProductType.GROUP_BUYING) {
            GroupBuying storage groupBuy = groupBuyings[productId];
            
            if (groupBuy.status != ProductTypes.GroupBuyingStatus.ACTIVE) {
                return (false, "Group buying not active");
            }
            
            if (block.timestamp > groupBuy.deadline) {
                return (false, "Group buying expired");
            }
            
            if (groupBuy.contributions[buyer] > 0) {
                return (false, "Already participated");
            }
            
            if (groupBuy.participantCount >= productGroup.maxGroupSize) {
                return (false, "Group is full");
            }
        }
        
        return (true, "");
    }
    
    // ============ RECEIVE FUNCTION ============
    
    receive() external payable {
        // Allow contract to receive ETH
    }
}