// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Website: <fill in before deploy>
// X:       <fill in before deploy>

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IMonoToken, IMonopolyHook} from "./interfaces/IMono.sol";

/// @title Seeder
/// @notice One-shot launch initializer, a target of the launch graph. Receives the whole supply and the launch ETH.
///         In one call: sends the START treasury to the hook, opens the pool, locks the rest of the supply as one
///         token-only position owned by 0xdEaD, buys with `buyEth` (the launch buy, normal hook fee), locks the bought
///         tokens with the rest of the ETH as a full-range position also owned by 0xdEaD, burns the tokens left over,
///         sends ETH dust to the dev. The team ends with zero tokens. Callable only by the graph deployer, once.
contract Seeder is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 public constant MIN_TICK_LOWER = -30_000;

    address public immutable dev;
    IPositionManager public immutable positionManager;
    IPoolManager public immutable poolManager;
    address public immutable deployer;

    bool public ignited;

    struct IgniteParams {
        uint160 sqrtPriceX96; // opening price (token per ETH, ETH = currency0)
        int24 tickLower; // bottom of the token-only position, >= MIN_TICK_LOWER
        int24 tickUpper; // top of it; must be <= the opening tick so the position holds only tokens
        uint256 minTokensOut; // slippage floor of the launch buy
        uint256 buyEth; // part of msg.value spent on the launch buy; the rest seeds the full-range position
    }

    error NotDeployer();
    error NotPoolManager();
    error AlreadyIgnited();
    error InvalidParams();
    error InsufficientOutput();
    error PostconditionFailed();

    event Ignited(
        address indexed token,
        address indexed hook,
        uint256 indexed mainPositionId,
        uint256 fullRangeId,
        uint256 bought,
        uint256 burned,
        uint256 ethDust
    );

    constructor(address dev_, IPositionManager positionManager_, address deployer_) {
        if (dev_ == address(0) || deployer_ == address(0)) revert InvalidParams();
        dev = dev_;
        positionManager = positionManager_;
        poolManager = positionManager_.poolManager();
        deployer = deployer_;
    }

    function ignite(address token, address hook, IgniteParams calldata p) external payable returns (uint256 mainId) {
        if (msg.sender != deployer) revert NotDeployer();
        if (ignited) revert AlreadyIgnited();
        ignited = true;

        PoolKey memory key = IMonopolyHook(hook).poolKey();
        if (
            p.buyEth == 0 || p.buyEth >= msg.value || Currency.unwrap(key.currency1) != token
                || p.tickLower < MIN_TICK_LOWER || p.tickLower >= p.tickUpper
        ) revert InvalidParams();

        // 1. the START treasury -> the hook, booked when the pool opens
        uint256 treasuryShare = IMonopolyHook(hook).TREASURY_SUPPLY();
        if (!IMonoToken(token).transfer(hook, treasuryShare)) revert PostconditionFailed();
        if (poolManager.initialize(key, p.sqrtPriceX96) < p.tickUpper) revert InvalidParams();

        // 2. the rest of the supply -> one token-only position, owned by 0xdEaD
        mainId = _mintTokenOnly(key, token, p.tickLower, p.tickUpper);

        // 3. the launch buy, through the hook like any trader
        uint256 bought = abi.decode(poolManager.unlock(abi.encode(key, p.buyEth)), (uint256));
        if (bought < p.minTokensOut) revert InsufficientOutput();

        // 4. the rest of the ETH + the tokens it needs -> one full-range position, owned by 0xdEaD
        uint256 lpEth = msg.value - p.buyEth;
        (uint256 fullRangeId, uint256 ethUsed) = _mintFullRange(key, token, bought, lpEth);

        // 5. burn every token still here; any ETH left -> dev
        uint256 burned = IMonoToken(token).balanceOf(address(this));
        if (burned != 0) IMonoToken(token).burn(burned);
        uint256 dust = address(this).balance;
        if (dust != 0) {
            (bool ok,) = dev.call{value: dust}("");
            if (!ok) revert PostconditionFailed();
        }
        // every token not burned is in the pool or in the treasury; nothing stays here
        if (
            IMonoToken(token).balanceOf(address(this)) != 0 || address(this).balance != 0
                || IMonoToken(token).balanceOf(address(poolManager)) + treasuryShare != IMonoToken(token).totalSupply()
        ) revert PostconditionFailed();
        emit Ignited(token, hook, mainId, fullRangeId, bought, burned, lpEth - ethUsed);
    }

    /// @dev The launch buy: exact ETH in, tokens out, settled from this contract's balance.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint256 buyEth) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(buyEth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        uint256 owed = uint256(-int256(delta.amount0()));
        if (owed != buyEth) revert PostconditionFailed();
        poolManager.sync(key.currency0);
        poolManager.settle{value: buyEth}();
        uint256 bought = uint256(int256(delta.amount1()));
        poolManager.take(key.currency1, address(this), bought);
        return abi.encode(bought);
    }

    function _mintTokenOnly(PoolKey memory key, address token, int24 tickLower, int24 tickUpper)
        private
        returns (uint256 tokenId)
    {
        uint256 supply = IMonoToken(token).balanceOf(address(this));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, supply);
        uint256 amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        while (amount1 > supply) {
            --liquidity;
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
        tokenId = positionManager.nextTokenId();
        if (!IMonoToken(token).transfer(address(positionManager), amount1)) revert PostconditionFailed();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, tickUpper, uint256(liquidity), uint128(0), uint128(amount1), DEAD, "");
        params[1] = abi.encode(key.currency1, amount1, false);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _mintFullRange(PoolKey memory key, address token, uint256 tokens, uint256 lpEth)
        private
        returns (uint256 tokenId, uint256 amount0)
    {
        int24 tickLower = TickMath.MIN_TICK;
        int24 tickUpper = TickMath.MAX_TICK;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        (uint160 sqrtP,,,) = poolManager.getSlot0(key.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sqrtLower, sqrtUpper, lpEth, tokens);
        uint256 amount1;
        (amount0, amount1) = _amounts(sqrtP, sqrtLower, sqrtUpper, liquidity);
        while (amount0 > lpEth || amount1 > tokens) {
            --liquidity;
            (amount0, amount1) = _amounts(sqrtP, sqrtLower, sqrtUpper, liquidity);
        }
        tokenId = positionManager.nextTokenId();
        if (!IMonoToken(token).transfer(address(positionManager), amount1)) revert PostconditionFailed();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SETTLE));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, tickLower, tickUpper, uint256(liquidity), uint128(amount0), uint128(amount1), DEAD, "");
        params[1] = abi.encode(key.currency0, amount0, false);
        params[2] = abi.encode(key.currency1, amount1, false);
        positionManager.modifyLiquidities{value: amount0}(abi.encode(actions, params), block.timestamp);
    }

    function _amounts(uint160 sqrtP, uint160 sqrtLower, uint160 sqrtUpper, uint128 liquidity)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtUpper, liquidity, true);
        amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtP, liquidity, true);
    }

    receive() external payable {}
}
