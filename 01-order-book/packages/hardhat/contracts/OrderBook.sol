import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OrderBook {
    // Incremented each time an order is placed, giving each order a unique ID
    uint256 private orderIdCounter = 0;

    // BUY: user wants tokenA and is paying with tokenB
    // SELL: user has tokenA and wants tokenB in return
    enum OrderType {
        BUY,
        SELL
    }

    // Represents a single open or closed order on the book
    struct Order {
        uint256 id; // unique order identifier
        address user; // address that placed the order
        OrderType orderType; // BUY or SELL
        address sellToken; // token the user is giving away (locked in escrow)
        address buyToken; // token the user wants to receive
        uint256 amount; // total tokens the user wants to trade
        uint256 price; // exchange rate: how many sellToken units per buyToken unit
        uint256 filled; // how much of amount has been matched so far
        bool open; // false once fully filled or cancelled
    }

    // Lookup any order by its ID
    mapping(uint256 => Order) public orders;

    // Emitted when a new buy or sell order is placed
    event OrderPlaced(
        uint256 order_id,
        address user,
        OrderType orderType,
        address sellToken,
        address buyToken,
        uint256 amount,
        uint256 price
    );

    // Emitted when two orders are matched and tokens are exchanged
    event OrderMatched(uint256 buyOrderId, uint256 sellOrderId, uint256 tradeAmount);

    // Emitted when an order owner cancels their open order and receives a refund
    event OrderCanceled(uint256 orderId);

    // Reverts when amount is zero — an order for nothing is invalid
    error InvalidAmount();

    // Reverts when price is zero — a free order would drain the contract
    error InvalidPrice();

    // Reverts when the buy order price is lower than the sell order price — no fair trade is possible
    error PriceMismatch();

    // Reverts when someone tries to cancel an order they did not place
    error UnauthorizedCancellation();

    // tokenA is PNPToken (PNPT) — the token being sold in sell orders
    IERC20 tokenA;

    // tokenB is FNBToken (FNBT) — the token used as payment in buy orders
    IERC20 tokenB;

    // Stores the two token addresses this order book trades between
    constructor(address _tokenA, address _tokenB) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

    function placeBuyOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount <= 0) revert InvalidAmount();
        if (price <= 0) revert InvalidPrice();

        orderId = orderIdCounter;

        // Buyer gives tokenB, wants tokenA — so sellToken=tokenB, buyToken=tokenA
        orders[orderId] = Order(
            orderId,
            msg.sender,
            OrderType.BUY,
            address(tokenB),
            address(tokenA),
            amount,
            price,
            0, // filled starts at zero
            true // order is open
        );

        SafeERC20.safeTransferFrom(tokenB, msg.sender, address(this), amount * price);

        emit OrderPlaced(orderId, msg.sender, OrderType.BUY, address(tokenB), address(tokenA), amount, price);

        orderIdCounter++;
    }

    function placeSellOrder(uint256 amount, uint256 price) external returns (uint256 orderId) {
        if (amount <= 0) revert InvalidAmount();
        if (price <= 0) revert InvalidPrice();

        orderId = orderIdCounter;

        // Seller gives tokenA, wants tokenB — so sellToken=tokenA, buyToken=tokenB
        orders[orderId] = Order(
            orderId,
            msg.sender,
            OrderType.SELL,
            address(tokenA),
            address(tokenB),
            amount,
            price,
            0, // filled starts at zero
            true // order is open
        );

        SafeERC20.safeTransferFrom(tokenA, msg.sender, address(this), amount);

        emit OrderPlaced(orderId, msg.sender, OrderType.SELL, address(tokenA), address(tokenB), amount, price);

        orderIdCounter++;
    }

    // Matches a buy order against a sell order, transferring tokens to each party.
    // Supports partial fills — only the minimum of the two remaining amounts is traded.
    function matchOrders(uint256 buyOrderId, uint256 sellOrderId) external {
        // Direct reference to the data on the blockchain, so updates to these variables will change the stored orders
        Order storage buyOrder = orders[buyOrderId];
        Order storage sellOrder = orders[sellOrderId];

        // Buy price must be at least as high as the sell price for a fair trade
        if (buyOrder.price < sellOrder.price) revert PriceMismatch();

        // How much each side still needs to trade
        uint256 buyRemaining = buyOrder.amount - buyOrder.filled;
        uint256 sellRemaining = sellOrder.amount - sellOrder.filled;

        // Only trade as much as both sides can cover
        uint256 tradeAmount = buyRemaining < sellRemaining ? buyRemaining : sellRemaining;

        // We always update the contract's state before making external calls(token transfers)
        // This prevents re-entrancy attacks and ensures the latest state is used

        // Update how much each order has been filled
        buyOrder.filled += tradeAmount;
        sellOrder.filled += tradeAmount;

        // Close orders that are now fully filled
        if (buyOrder.filled == buyOrder.amount) buyOrder.open = false;
        if (sellOrder.filled == sellOrder.amount) sellOrder.open = false;

        // Send tokenA (PNPT) to the buyer
        SafeERC20.safeTransfer(tokenA, buyOrder.user, tradeAmount);

        // Send tokenB (FNBT) to the seller — paid at the buy order's price
        SafeERC20.safeTransfer(tokenB, sellOrder.user, tradeAmount * buyOrder.price);

        emit OrderMatched(buyOrderId, sellOrderId, tradeAmount);
    }

    // Cancels an open order and refunds the escrowed tokens back to the order owner.
    // Only the address that placed the order may cancel it.
    function cancelOrder(uint256 orderId) external {
        Order storage order = orders[orderId];

        // Only the order owner can cancel
        if (order.user != msg.sender) revert UnauthorizedCancellation();

        order.open = false;

        // Tokens not yet matched are still sitting in the contract — refund them
        uint256 leftover = order.amount - order.filled;

        if (order.orderType == OrderType.BUY) {
            // Buyer locked up leftover * price FNBT upfront — refund the unspent portion
            SafeERC20.safeTransfer(tokenB, order.user, leftover * order.price);
        } else {
            // Seller locked up the tokens themselves — refund the unsold portion
            SafeERC20.safeTransfer(tokenA, order.user, leftover);
        }

        emit OrderCanceled(orderId);
    }

    // Returns how many tokens are still unfilled on an order
    function remaining(uint256 orderId) external view returns (uint256) {
        return orders[orderId].amount - orders[orderId].filled;
    }

    // Returns true if the order is still active (not fully filled and not cancelled)
    function isOpen(uint256 orderId) external view returns (bool) {
        return orders[orderId].open;
    }
}
