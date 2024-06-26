// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { BaseHook } from "v4-periphery/BaseHook.sol";

import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { Pool } from "v4-core/src/libraries/Pool.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";
import { FixedPoint128 } from "v4-core/src/libraries/FixedPoint128.sol";
import { Position } from "v4-core/src/libraries/Position.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta, BeforeSwapDeltaLibrary } from "v4-core/src/types/BeforeSwapDelta.sol";

contract IncentivesHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using Pool for Pool.State;
    using StateLibrary for IPoolManager;

    PoolKey public poolKey;

    uint256 public rewardRate = 11574074074074;
    uint256 public rewardReserve = 100e18;
    uint256 public periodFinish = block.timestamp + 7 days;

    struct RewardInfo {
        uint256 rewardGrowthOutsideX128;
    }

    uint256 public rewardGrowthGlobalX128;
    uint256 public stakedLiquidity;
    mapping(int24 => RewardInfo) public ticks;

    int24 private activeTick;
    uint256 private _lastUpdated;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) { }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick,
        bytes calldata hookData
    ) external override returns (bytes4) {
        poolKey = key;
        activeTick = tick; // We need to know where to begin

        // TODO: Use `hookData` to initialize with reward info
        // Uhh.. maybe not? This PoC maybe just do the math part

        return BaseHook.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // We track all rewards for the previous active tick.
        _updateRewardsGrowthGlobal();

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        (, int24 tick,,) = poolManager.getSlot0(key.toId());

        // Update the tick after the swap so future rewards go to active tick
        activeTick = tick;

        int24 zTick = tick;
        // This step ideally happens in the pool manager since it already does the compute step for crossing through ticks,
        // but we don't have that luxury so we'll do it here.
        if (zTick < activeTick) {
            for (; tick < activeTick;) {
                ticks[zTick].rewardGrowthOutsideX128 = rewardGrowthGlobalX128 - ticks[zTick].rewardGrowthOutsideX128;

                unchecked {
                    tick += key.tickSpacing;
                }
            }
        } else {
            for (; activeTick < zTick;) {
                ticks[zTick].rewardGrowthOutsideX128 = rewardGrowthGlobalX128 - ticks[zTick].rewardGrowthOutsideX128;

                unchecked {
                    tick -= key.tickSpacing;
                }
            }
        }

        activeTick = tick;

        return (BaseHook.afterSwap.selector, 0);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        // Let's update rewards so users don't lose them on removal
        _updateRewardsGrowthGlobal();

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        Position.Info memory positionInfo =
            StateLibrary.getPosition(poolManager, id, sender, params.tickLower, params.tickUpper, params.salt);

        stakedLiquidity -= positionInfo.liquidity;

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        // We use this hook to update state before a liquidity change has happened.
        _updateRewardsGrowthGlobal();

        return BaseHook.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, BalanceDelta) {
        PoolId id = key.toId();
        Position.Info memory positionInfo =
            StateLibrary.getPosition(poolManager, id, sender, params.tickLower, params.tickUpper, params.salt);

        stakedLiquidity += positionInfo.liquidity;

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    // Internal Functions
    function _updateRewardsGrowthGlobal() internal {
        uint256 timestamp = block.timestamp;
        uint256 timeDelta = timestamp - _lastUpdated; // skip if second call in same block

        if (timeDelta != 0) {
            if (rewardReserve > 0) {
                uint256 reward = rewardRate * timeDelta;
                if (reward > rewardReserve) reward = rewardReserve; // give everything if expected is more than allocated
                if (stakedLiquidity > 0) {
                    // ^ This only exists to not burn all rewards if no staked liquidity
                    rewardGrowthGlobalX128 += reward * FixedPoint128.Q128 / stakedLiquidity;
                    rewardReserve -= reward;
                }
            }

            _lastUpdated = timestamp;
        }
    }

    function getRewardGrowthInside(int24 tickLower, int24 tickUpper, int24 tickCurrent)
        public
        view
        returns (uint256 rewardGrowthInsideX128)
    {
        RewardInfo storage lower = ticks[tickLower];
        RewardInfo storage upper = ticks[tickUpper];

        // calculate reward growth below
        uint256 rewardGrowthBelowX128;
        if (tickCurrent >= tickLower) {
            rewardGrowthBelowX128 = lower.rewardGrowthOutsideX128;
        } else {
            rewardGrowthBelowX128 = rewardGrowthGlobalX128 - lower.rewardGrowthOutsideX128;
        }

        // calculate reward growth above
        uint256 rewardGrowthAboveX128;
        if (tickCurrent < tickUpper) {
            rewardGrowthAboveX128 = upper.rewardGrowthOutsideX128;
        } else {
            rewardGrowthAboveX128 = rewardGrowthGlobalX128 - upper.rewardGrowthOutsideX128;
        }

        rewardGrowthInsideX128 = rewardGrowthGlobalX128 - rewardGrowthBelowX128 - rewardGrowthAboveX128;
    }

    // Interactions
    function earned(int24 tickLower, int24 tickUpper, int256 liquidity)
        public
        returns (uint256 scalar, uint256 claimable)
    {
        _updateRewardsGrowthGlobal();

        uint256 timeDelta = block.timestamp - _lastUpdated;

        uint256 rewardPerTokenInsideInitialX128 = 0; // NOTE: replace with position level tracking, when available in V4
        // ^ Also track last known feeGrowthInside
        uint256 rewardPerTokenInsideX128 = getRewardGrowthInside(tickLower, tickUpper, activeTick);

        scalar = (rewardPerTokenInsideX128 - rewardPerTokenInsideInitialX128) * uint256(liquidity) / FixedPoint128.Q128;

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            poolManager.getFeeGrowthInside(poolKey.toId(), tickLower, tickUpper);

        claimable = uint256(liquidity) * FixedPoint128.Q128 / (feeGrowthInside0X128 + feeGrowthInside1X128);
    }
}
