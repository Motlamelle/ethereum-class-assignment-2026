// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import { Actions } from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import { IPositionManager } from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

// Minimal interface to read the Permit2 address stored inside PositionManager.
// PositionManager inherits Permit2Forwarder which exposes permit2 as a public immutable.
// address and IAllowanceTransfer share the same ABI encoding so the cast is safe.
interface IWithPermit2 {
    function permit2() external view returns (address);
}

// Manages creation and liquidity provisioning of a Uniswap v4 PNPT/FNBT pool.
// Inherits Ownable to restrict pool creation to the contract owner.
contract RewardTokensManager is Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // 0.3% swap fee, expressed in fee units where 1_000_000 = 100%
    uint24 public constant FEE_TIER = 3000;

    // Tick spacing paired with the 0.3% fee tier in Uniswap v3-style fee/spacing tables
    int24 public constant TICK_SPACING = 60;

    // No hook contract attached to this pool
    address public constant HOOKS = address(0);

    // Tick for price = 10 (token1 per token0): floor(log(10) / log(1.0001)) = 23027.
    // 1 FNBT = R0.10, 1 PNPT = R0.01 → 1 FNBT buys 10 PNPT.
    // Sign is flipped when PNPT is currency0 because then price = FNBT/PNPT = 0.1.
    int24 private constant PRICE_10_TICK = 23027;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;

    // Permit2 address read from PositionManager at deploy time so callers don't need to pass it
    address public immutable permit2;

    IERC20 public immutable pnpToken;
    IERC20 public immutable fnbToken;

    // Canonical sorted pair — Uniswap requires the lower address to be currency0
    Currency public immutable currency0;
    Currency public immutable currency1;

    // Assignment-implied tick; sign determined by which token ends up as currency0
    int24 public immutable targetTick;

    // Pool key that uniquely identifies this PNPT/FNBT pool inside PoolManager
    PoolKey private poolKey;

    // Tracks pools this contract has successfully initialized
    mapping(bytes32 => bool) public createdPools;

    // Emitted when the PNPT/FNBT pool is initialized in PoolManager
    event PoolCreated(
        bytes32 indexed poolId,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks,
        uint160 sqrtPriceX96
    );

    // Emitted when a concentrated liquidity position is minted in the pool
    event LiquidityMinted(
        bytes32 indexed poolId,
        uint256 positionId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    // Reverts when the tick range does not cover the assignment-implied price tick
    error TickRangeDoesNotCoverAssignmentPrice();

    // Reverts when both desired amounts are zero — nothing to deposit
    error InvalidAmount();

    // Reverts when tickLower >= tickUpper
    error InvalidTickRange();

    // Stores contract references, sorts tokens into canonical Uniswap order,
    // derives the assignment-implied target tick, and builds the pool key.
    constructor(
        address _poolManager,
        address _positionManager,
        address _pnpToken,
        address _fnbToken
    ) Ownable(msg.sender) {
        poolManager     = IPoolManager(_poolManager);
        positionManager = IPositionManager(_positionManager);

        // Read Permit2 from PositionManager — it is stored there as a public immutable
        permit2 = IWithPermit2(_positionManager).permit2();

        pnpToken = IERC20(_pnpToken);
        fnbToken = IERC20(_fnbToken);

        // Sort tokens so the lower address becomes currency0 (Uniswap canonical ordering)
        if (_pnpToken < _fnbToken) {
            currency0  = Currency.wrap(_pnpToken);
            currency1  = Currency.wrap(_fnbToken);
            // price = FNBT/PNPT = 0.1, so the implied tick is -23027
            targetTick = -PRICE_10_TICK;
        } else {
            currency0  = Currency.wrap(_fnbToken);
            currency1  = Currency.wrap(_pnpToken);
            // price = PNPT/FNBT = 10, so the implied tick is +23027
            targetTick = PRICE_10_TICK;
        }

        // Build the pool key once — reused in all pool and liquidity operations
        poolKey = PoolKey({
            currency0:   currency0,
            currency1:   currency1,
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(HOOKS)
        });
    }

    // Returns the assignment-implied tick derived from 1 FNBT = 10 PNPT,
    // adjusted for the actual token ordering in this pool.
    function getTargetTick() public view returns (int24) {
        return targetTick;
    }

    // Returns the PoolId (bytes32) for the PNPT/FNBT pool inside PoolManager
    function getPoolId() public view returns (bytes32) {
        return PoolId.unwrap(poolKey.toId());
    }

    // Returns the two token addresses in canonical Uniswap-sorted order
    function getCanonicalCurrencies() public view returns (address, address) {
        return (Currency.unwrap(currency0), Currency.unwrap(currency1));
    }

    // Initialises the PNPT/FNBT pool in PoolManager at the given starting price.
    // Restricted to the contract owner (onlyOwner) because an incorrect starting price
    // would set a misleading market price that cannot be changed after initialisation.
    function createPool(uint160 sqrtPriceX96) external onlyOwner returns (bytes32 poolId) {
        // Register the pool inside the singleton PoolManager using the stored pool key.
        // After this call the pool exists and can accept swaps and liquidity.
        poolManager.initialize(poolKey, sqrtPriceX96);

        // Derive the poolId by hashing all four fields of the pool key
        poolId = PoolId.unwrap(poolKey.toId());

        // Record that this contract created the pool so it can be verified externally
        createdPools[poolId] = true;

        emit PoolCreated(
            poolId,
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            FEE_TIER,
            TICK_SPACING,
            HOOKS,
            sqrtPriceX96
        );
    }

    // Mints a concentrated liquidity position in [tickLower, tickUpper].
    // Pulls both token amounts from msg.sender, routes settlement through Permit2
    // and PositionManager, then refunds any unspent dust back to the caller.
    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external returns (uint256 positionId, bytes32 poolId) {
        // 1) Validate user inputs and tick constraints
        if (amount0Desired == 0 && amount1Desired == 0) revert InvalidAmount();
        if (tickLower >= tickUpper) revert InvalidTickRange();
        // Ticks must sit on the pool's tick spacing grid — unaligned ticks are rejected by PoolManager
        if (tickLower % TICK_SPACING != 0 || tickUpper % TICK_SPACING != 0) revert InvalidTickRange();

        // 2) Ensure the chosen range includes the assignment-implied price tick.
        // targetTick corresponds to 1 FNBT = 10 PNPT — liquidity outside this range
        // would not be active at the assignment price.
        if (targetTick < tickLower || targetTick > tickUpper) revert TickRangeDoesNotCoverAssignmentPrice();
        // 3) Resolve the pool ID from the stored pool key.
        // toId() hashes all four key fields — same key always produces the same PoolId.
        PoolId pid = poolKey.toId();
        poolId = PoolId.unwrap(pid);
        // 4) Compute liquidity from desired amounts at the current pool price.
        // sqrtPriceX96 is the current price; the library uses it to determine which
        // token(s) are needed and how much liquidity each desired amount can support.
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(pid);
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceAX96,
            sqrtPriceBX96,
            amount0Desired,
            amount1Desired
        );
        // 5) Pull desired token amounts from the caller into this contract.
        // Caller must have approved this contract on both tokens before calling.
        // Only pull non-zero amounts — one side may be zero if price is outside the range.
        if (amount0Desired > 0) {
            IERC20(Currency.unwrap(currency0)).transferFrom(msg.sender, address(this), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(Currency.unwrap(currency1)).transferFrom(msg.sender, address(this), amount1Desired);
        }
        // 6) Approve Permit2 so PositionManager can pull tokens from this contract during settlement.
        // PositionManager calls permit2.transferFrom(address(this), poolManager, amount, token).
        // Permit2 checks this contract's ERC20 allowance before executing the transfer.
        IERC20(Currency.unwrap(currency0)).approve(permit2, amount0Desired);
        IERC20(Currency.unwrap(currency1)).approve(permit2, amount1Desired);
        // 7) Prepare and execute PositionManager mint actions.
        // Read nextTokenId before minting — that sequential ID will be assigned to this position.
        positionId = positionManager.nextTokenId();

        // Encode two sequential actions: create the position, then settle the token deltas
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);

        // MINT_POSITION: pool identity, tick range, liquidity, slippage limits, NFT recipient, hook data
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            type(uint128).max, // amount0Max: no slippage guard needed for this assignment
            type(uint128).max, // amount1Max: no slippage guard needed for this assignment
            msg.sender,        // position NFT is sent directly to the caller
            bytes("")          // no hook data — this pool has no hooks
        );

        // SETTLE_PAIR: the two currencies whose deltas need to be settled after the mint
        params[1] = abi.encode(currency0, currency1);

        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
        );
        // 8) Verify mint succeeded — nextTokenId must have incremented by exactly 1
        require(positionManager.nextTokenId() == positionId + 1, "Mint failed");
        // 9) Return any unspent token dust to the caller, then emit the assignment event.
        // Dust occurs when the current price is outside the range, making one token unnecessary.
        uint256 dust0 = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        uint256 dust1 = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        if (dust0 > 0) IERC20(Currency.unwrap(currency0)).transfer(msg.sender, dust0);
        if (dust1 > 0) IERC20(Currency.unwrap(currency1)).transfer(msg.sender, dust1);

        emit LiquidityMinted(poolId, positionId, msg.sender, tickLower, tickUpper, liquidity);
    }
}
