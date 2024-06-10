// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import { IHooks } from "v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "v4-core/src/libraries/Hooks.sol";
import { TickMath } from "v4-core/src/libraries/TickMath.sol";
import { IPoolManager } from "v4-core/src/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/src/types/PoolKey.sol";
import { BalanceDelta } from "v4-core/src/types/BalanceDelta.sol";
import { PoolId, PoolIdLibrary } from "v4-core/src/types/PoolId.sol";
import { CurrencyLibrary, Currency } from "v4-core/src/types/Currency.sol";
import { PoolSwapTest } from "v4-core/src/test/PoolSwapTest.sol";
import { Deployers } from "v4-core/test/utils/Deployers.sol";
import { IncentivesHook } from "../src/IncentivesHook.sol";
import { HookMiner } from "./utils/HookMiner.sol";
import { StateLibrary } from "v4-core/src/libraries/StateLibrary.sol";

contract IncentivesHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    IncentivesHook hook;
    PoolId poolId;

    address bob = makeAddr("bob");
    address alice = makeAddr("alice");
    address dylan = makeAddr("dylan");

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.AFTER_SWAP_FLAG
        );
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flags, type(IncentivesHook).creationCode, abi.encode(address(manager)));
        hook = new IncentivesHook{ salt: salt }(IPoolManager(address(manager)));
        require(address(hook) == hookAddress, "hook address mismatch");

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 1, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provide liquidity to the pool
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-100, 100, 10 ether, 0), ZERO_BYTES
        );
        modifyLiquidityRouter.modifyLiquidity(
            key, IPoolManager.ModifyLiquidityParams(-200, 200, 10 ether, 0), ZERO_BYTES
        );
    }

    function test_Earned() public {
        bool zeroForOne = true;
        int256 amountSpecified = -1e18;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        vm.warp(block.timestamp + 1 days);

        (uint256 scalar1, uint256 claimable1) = hook.earned(-100, 100, 1e18);
        (uint256 scalar2, uint256 claimable2) = hook.earned(-200, 200, 1e18);
        console2.log("1", scalar1, claimable1);
        console2.log("2", scalar2, claimable2);

        // // after 1 days the user will get some rewards
        // amount = hook.earned(poolId, bob);
        // assertGt(amount, 0);
    }
}
