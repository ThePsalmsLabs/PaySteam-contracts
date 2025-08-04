// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Permit2 interfaces
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }
    
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }
    
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }
    
    function permitTransferFrom(
        PermitTransferFrom memory permit,
        SignatureTransferDetails memory transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

// Uniswap V3 Router interface (simplified)
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

// WETH interface
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Commerce Payments Protocol Interface
interface ICommercePaymentsProtocol {
    struct TransferIntent {
        uint256 recipientAmount;
        uint256 deadline;
        address payable recipient;
        address recipientCurrency;
        address refundDestination;
        uint256 feeAmount;
        bytes16 id;
        address operator;
        bytes signature;
        bytes prefix;
        address sender;
        address token;
    }
    
    struct Permit2SignatureTransferData {
        ISignatureTransfer.PermitTransferFrom permit;
        ISignatureTransfer.SignatureTransferDetails transferDetails;
        bytes signature;
    }
    
    struct EIP2612SignatureTransferData {
        address owner;
        bytes signature;
    }
    
    function registerOperator(address _feeDestination) external;
    function transferNative(TransferIntent calldata _intent) external payable;
    function transferToken(TransferIntent calldata _intent, Permit2SignatureTransferData calldata _signatureTransferData) external;
    function transferTokenPreApproved(TransferIntent calldata _intent) external;
    function swapAndTransferUniswapV3Native(TransferIntent calldata _intent, uint24 poolFeesTier) external payable;
    function swapAndTransferUniswapV3Token(TransferIntent calldata _intent, Permit2SignatureTransferData calldata _signatureTransferData, uint24 poolFeesTier) external;
    function swapAndTransferUniswapV3TokenPreApproved(TransferIntent calldata _intent, uint24 poolFeesTier) external;
    function wrapAndTransfer(TransferIntent calldata _intent) external payable;
    function unwrapAndTransfer(TransferIntent calldata _intent, Permit2SignatureTransferData calldata _signatureTransferData) external;
    function unwrapAndTransferPreApproved(TransferIntent calldata _intent) external;
    function isOperatorRegistered(address operator) external view returns (bool);
    function getOperatorFeeDestination(address operator) external view returns (address);
    
    event Transferred(address indexed operator, bytes16 id, address recipient, address sender, uint256 spentAmount, address spentCurrency);
    event OperatorRegistered(address operator, address feeDestination);
    
    error InvalidSignature();
    error ExpiredIntent();
    error NullRecipient();
    error AlreadyProcessed();
    error InexactTransfer();
    error OperatorNotRegistered();
    error InvalidNativeAmount(int256 delta);
    error SwapFailedString(string reason);
    error SwapFailedBytes(bytes reason);
}

// Updated Merchant Interface
interface IMerchantMarketplace {
    function marketplaceFee() external returns (uint256);
    function processPayment(
        address merchant,
        uint256 productId,
        uint128 quantity,
        bytes16 paymentId,
        address paymentToken,
        uint256 paymentAmount
    ) external returns (bool);
}

// Product Types Library
library ProductTypes {
    enum ProductType { SINGLE, BULK, GROUP_BUYING }
    enum PurchaseStatus { PENDING, COMPLETED, REFUNDED, EXPIRED }
    enum GroupBuyingStatus { ACTIVE, COMPLETED, EXPIRED, CANCELLED }
}

// Main Ecommerce Protocol Contract
contract EcommerceProtocol is ICommercePaymentsProtocol, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // Constants
    address public constant WETH = 0x4200000000000000000000000000000000000006; // Base WETH
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Permit2 contract
    address public constant UNISWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481; // Base Uniswap V3 Router
    uint256 public constant OPERATOR_FEE_BASIS_POINTS = 50; // 0.5%
    
    // State variables
    mapping(address => address) public operatorFeeDestinations;
    mapping(bytes16 => bool) public processedIntents;
    mapping(address => bool) public registeredOperators;
    address public marketplace;
    
    // Events
    event MarketplaceUpdated(address indexed oldMarketplace, address indexed newMarketplace);
    event PaymentProcessed(
        bytes16 indexed paymentId,
        address indexed merchant,
        address indexed buyer,
        uint256 productId,
        uint256 amount,
        address token
    );
    
    constructor(address _marketplace) Ownable(msg.sender) {
        marketplace = _marketplace;
    }
    
    // Operator registration
    function registerOperator(address _feeDestination) external override {
        require(_feeDestination != address(0), "Invalid fee destination");
        operatorFeeDestinations[msg.sender] = _feeDestination;
        registeredOperators[msg.sender] = true;
        emit OperatorRegistered(msg.sender, _feeDestination);
    }
    
    function isOperatorRegistered(address operator) external view override returns (bool) {
        return registeredOperators[operator];
    }
    
    function getOperatorFeeDestination(address operator) external view override returns (address) {
        return operatorFeeDestinations[operator];
    }
    
    // Native ETH transfers
    function transferNative(TransferIntent calldata _intent) external payable override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        
        require(msg.value >= _intent.recipientAmount + _intent.feeAmount, "Insufficient payment");
        
        // Transfer to recipient
        (bool success,) = _intent.recipient.call{value: _intent.recipientAmount}("");
        require(success, "Transfer failed");
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            (success,) = feeDestination.call{value: _intent.feeAmount}("");
            require(success, "Fee transfer failed");
        }
        
        // Refund excess
        if (msg.value > _intent.recipientAmount + _intent.feeAmount) {
            (success,) = _intent.refundDestination.call{value: msg.value - _intent.recipientAmount - _intent.feeAmount}("");
            require(success, "Refund failed");
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, msg.value, address(0));
    }
    
    // Token transfers with Permit2
    function transferToken(
        TransferIntent calldata _intent,
        Permit2SignatureTransferData calldata _signatureTransferData
    ) external override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        
        // Use Permit2 to transfer tokens
        ISignatureTransfer(PERMIT2).permitTransferFrom(
            _signatureTransferData.permit,
            _signatureTransferData.transferDetails,
            _intent.sender,
            _signatureTransferData.signature
        );
        
        // Transfer to recipient
        IERC20(_intent.recipientCurrency).safeTransfer(_intent.recipient, _intent.recipientAmount);
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            IERC20(_intent.recipientCurrency).safeTransfer(feeDestination, _intent.feeAmount);
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, _intent.recipientAmount + _intent.feeAmount, _intent.recipientCurrency);
    }
    
    // Pre-approved token transfers
    function transferTokenPreApproved(TransferIntent calldata _intent) external override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        
        // Transfer from sender to contract first
        IERC20(_intent.token).safeTransferFrom(_intent.sender, address(this), _intent.recipientAmount + _intent.feeAmount);
        
        // Transfer to recipient
        IERC20(_intent.recipientCurrency).safeTransfer(_intent.recipient, _intent.recipientAmount);
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            IERC20(_intent.recipientCurrency).safeTransfer(feeDestination, _intent.feeAmount);
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, _intent.recipientAmount + _intent.feeAmount, _intent.token);
    }
    
    // Swap and transfer with Uniswap V3 (Native)
    function swapAndTransferUniswapV3Native(
        TransferIntent calldata _intent,
        uint24 poolFeesTier
    ) external payable override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        
        // Wrap ETH to WETH
        IWETH(WETH).deposit{value: msg.value}();
        
        // Approve router
        IERC20(WETH).approve(UNISWAP_ROUTER, msg.value);
        
        // Perform swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: _intent.recipientCurrency,
            fee: poolFeesTier,
            recipient: address(this),
            deadline: _intent.deadline,
            amountIn: msg.value,
            amountOutMinimum: _intent.recipientAmount + _intent.feeAmount,
            sqrtPriceLimitX96: 0
        });
        
        uint256 amountOut = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(params);
        require(amountOut >= _intent.recipientAmount + _intent.feeAmount, "Insufficient output");
        
        // Transfer to recipient
        IERC20(_intent.recipientCurrency).transfer(_intent.recipient, _intent.recipientAmount);
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            IERC20(_intent.recipientCurrency).transfer(feeDestination, _intent.feeAmount);
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, msg.value, WETH);
    }
    
    // Swap and transfer with Uniswap V3 (Token)
    function swapAndTransferUniswapV3Token(
        TransferIntent calldata _intent,
        Permit2SignatureTransferData calldata _signatureTransferData,
        uint24 poolFeesTier
    ) external override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        
        // Use Permit2 to transfer tokens
        ISignatureTransfer(PERMIT2).permitTransferFrom(
            _signatureTransferData.permit,
            _signatureTransferData.transferDetails,
            _intent.sender,
            _signatureTransferData.signature
        );
        
        uint256 amountIn = _signatureTransferData.transferDetails.requestedAmount;
        
        // Approve router
        IERC20(_intent.token).approve(UNISWAP_ROUTER, amountIn);
        
        // Perform swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _intent.token,
            tokenOut: _intent.recipientCurrency,
            fee: poolFeesTier,
            recipient: address(this),
            deadline: _intent.deadline,
            amountIn: amountIn,
            amountOutMinimum: _intent.recipientAmount + _intent.feeAmount,
            sqrtPriceLimitX96: 0
        });
        
        uint256 amountOut = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(params);
        require(amountOut >= _intent.recipientAmount + _intent.feeAmount, "Insufficient output");
        
        // Transfer to recipient
        IERC20(_intent.recipientCurrency).transfer(_intent.recipient, _intent.recipientAmount);
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            IERC20(_intent.recipientCurrency).transfer(feeDestination, _intent.feeAmount);
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, amountIn, _intent.token);
    }
    
    // Pre-approved swap and transfer
    function swapAndTransferUniswapV3TokenPreApproved(
        TransferIntent calldata _intent,
        uint24 poolFeesTier
    ) external override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        
        // Calculate required input amount (approximate)
        uint256 totalOutput = _intent.recipientAmount + _intent.feeAmount;
        uint256 amountIn = totalOutput * 11000 / 10000; // 10% slippage buffer
        
        // Transfer from sender
        IERC20(_intent.token).safeTransferFrom(_intent.sender, address(this), amountIn);
        
        // Approve router
        IERC20(_intent.token).approve(UNISWAP_ROUTER, amountIn);
        
        // Perform swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _intent.token,
            tokenOut: _intent.recipientCurrency,
            fee: poolFeesTier,
            recipient: address(this),
            deadline: _intent.deadline,
            amountIn: amountIn,
            amountOutMinimum: totalOutput,
            sqrtPriceLimitX96: 0
        });
        
        uint256 amountOut = ISwapRouter(UNISWAP_ROUTER).exactInputSingle(params);
        require(amountOut >= totalOutput, "Insufficient output");
        
        // Transfer to recipient
        IERC20(_intent.recipientCurrency).transfer(_intent.recipient, _intent.recipientAmount);
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            IERC20(_intent.recipientCurrency).transfer(feeDestination, _intent.feeAmount);
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, amountIn, _intent.token);
    }
    
    // Wrap ETH and transfer
    function wrapAndTransfer(TransferIntent calldata _intent) external payable override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        require(_intent.recipientCurrency == WETH, "Must transfer WETH");
        
        // Wrap ETH
        IWETH(WETH).deposit{value: msg.value}();
        
        // Transfer WETH to recipient
        IERC20(WETH).transfer(_intent.recipient, _intent.recipientAmount);
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            IERC20(WETH).transfer(feeDestination, _intent.feeAmount);
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, msg.value, WETH);
    }
    
    // Unwrap WETH and transfer
    function unwrapAndTransfer(
        TransferIntent calldata _intent,
        Permit2SignatureTransferData calldata _signatureTransferData
    ) external override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        require(_intent.token == WETH, "Must unwrap WETH");
        
        // Use Permit2 to transfer WETH
        ISignatureTransfer(PERMIT2).permitTransferFrom(
            _signatureTransferData.permit,
            _signatureTransferData.transferDetails,
            _intent.sender,
            _signatureTransferData.signature
        );
        
        // Unwrap WETH
        uint256 totalAmount = _intent.recipientAmount + _intent.feeAmount;
        IWETH(WETH).withdraw(totalAmount);
        
        // Transfer ETH to recipient
        (bool success,) = _intent.recipient.call{value: _intent.recipientAmount}("");
        require(success, "Transfer failed");
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            (success,) = feeDestination.call{value: _intent.feeAmount}("");
            require(success, "Fee transfer failed");
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, totalAmount, WETH);
    }
    
    // Pre-approved unwrap and transfer
    function unwrapAndTransferPreApproved(TransferIntent calldata _intent) external override nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        require(_intent.token == WETH, "Must unwrap WETH");
        
        uint256 totalAmount = _intent.recipientAmount + _intent.feeAmount;
        
        // Transfer WETH from sender
        IERC20(WETH).transferFrom(_intent.sender, address(this), totalAmount);
        
        // Unwrap WETH
        IWETH(WETH).withdraw(totalAmount);
        
        // Transfer ETH to recipient
        (bool success,) = _intent.recipient.call{value: _intent.recipientAmount}("");
        require(success, "Transfer failed");
        
        // Transfer operator fee
        if (_intent.feeAmount > 0) {
            address feeDestination = operatorFeeDestinations[_intent.operator];
            (success,) = feeDestination.call{value: _intent.feeAmount}("");
            require(success, "Fee transfer failed");
        }
        
        processedIntents[_intent.id] = true;
        emit Transferred(_intent.operator, _intent.id, _intent.recipient, _intent.sender, totalAmount, WETH);
    }
    
    // Ecommerce-specific payment processing
    function processEcommercePayment(
        TransferIntent calldata _intent,
        uint256 productId,
        uint128 quantity,
        ProductTypes.ProductType productType
    ) external payable nonReentrant whenNotPaused {
        _validateIntent(_intent);
        _validateSignature(_intent);
        
        // Process payment based on product type
        if (productType == ProductTypes.ProductType.SINGLE) {
            _processSingleProductPayment(_intent, productId, quantity);
        } else if (productType == ProductTypes.ProductType.BULK) {
            _processBulkProductPayment(_intent, productId, quantity);
        } else if (productType == ProductTypes.ProductType.GROUP_BUYING) {
            _processGroupBuyingPayment(_intent, productId, quantity);
        }
        
        processedIntents[_intent.id] = true;
        
        emit PaymentProcessed(
            _intent.id,
            _intent.recipient,
            _intent.sender,
            productId,
            _intent.recipientAmount,
            _intent.recipientCurrency
        );
    }
    
    // Internal validation functions
    function _validateIntent(TransferIntent calldata _intent) internal view {
        if (processedIntents[_intent.id]) revert AlreadyProcessed();
        if (block.timestamp > _intent.deadline) revert ExpiredIntent();
        if (_intent.recipient == address(0)) revert NullRecipient();
        if (!registeredOperators[_intent.operator]) revert OperatorNotRegistered();
    }
    
    function _validateSignature(TransferIntent calldata _intent) internal pure {
        // Implement signature validation logic
        // This would verify the operator's signature over the intent data
        // For now, we'll skip the actual cryptographic verification
        if (_intent.signature.length == 0) revert InvalidSignature();
    }
    
    function _processSingleProductPayment(
        TransferIntent calldata _intent,
        uint256 productId,
        uint128 quantity
    ) internal {
        // Call marketplace to process the payment
        bool success = IMerchantMarketplace(marketplace).processPayment(
            _intent.recipient,
            productId,
            quantity,
            _intent.id,
            _intent.recipientCurrency,
            _intent.recipientAmount
        );
        require(success, "Payment processing failed");
    }
    
    function _processBulkProductPayment(
        TransferIntent calldata _intent,
        uint256 productId,
        uint128 quantity
    ) internal {
        // Similar to single product but with bulk pricing logic
        bool success = IMerchantMarketplace(marketplace).processPayment(
            _intent.recipient,
            productId,
            quantity,
            _intent.id,
            _intent.recipientCurrency,
            _intent.recipientAmount
        );
        require(success, "Bulk payment processing failed");
    }
    
    function _processGroupBuyingPayment(
        TransferIntent calldata _intent,
        uint256 productId,
        uint128 quantity
    ) internal {
        // Handle group buying contribution
        bool success = IMerchantMarketplace(marketplace).processPayment(
            _intent.recipient,
            productId,
            quantity,
            _intent.id,
            _intent.recipientCurrency,
            _intent.recipientAmount
        );
        require(success, "Group buying payment processing failed");
    }
    
    // Admin functions
    function updateMarketplace(address _marketplace) external onlyOwner {
        address oldMarketplace = marketplace;
        marketplace = _marketplace;
        emit MarketplaceUpdated(oldMarketplace, _marketplace);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool success,) = owner().call{value: amount}("");
            require(success, "ETH withdrawal failed");
        } else {
            IERC20(token).transfer(owner(), amount);
        }
    }
    
    // Receive function for ETH
    receive() external payable {}
}