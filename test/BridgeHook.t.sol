// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {BridgeHook} from "../src/BridgeHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract TestBridgeHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    BridgeHook hook;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);

        // Mine an address that has flags set for
        // the hook functions we want
        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            0,
            type(BridgeHook).creationCode,
            abi.encode(manager)
        );

        // Deploy our hook
        hook = new BridgeHook{salt: salt}(
            manager,
            address(this),
            1999
        );

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_RATIO_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // No additional `initData`
        );
    }

    /*
        currentTick = 0
        We are adding liquidity at tickLower = -60, tickUpper = 60

        New liquidity must not change the token price

        We saw an equation in "Ticks and Q64.96 Numbers" of how to calculate amounts of
        x and y when adding liquidity. Given the three variables - x, y, and L - we need to set value of one.

        We'll set liquidityDelta = 1 ether, i.e. ΔL = 1 ether
        since the `modifyLiquidity` function takes `liquidityDelta` as an argument instead of
        specific values for `x` and `y`.

        Then, we can calculate Δx and Δy:
        Δx = Δ (L/SqrtPrice) = ( L * (SqrtPrice_tick - SqrtPrice_currentTick) ) / (SqrtPrice_tick * SqrtPrice_currentTick)
        Δy = Δ (L * SqrtPrice) = L * (SqrtPrice_currentTick - SqrtPrice_tick)

        So, we can calculate how much x and y we need to provide
        The python script below implements code to compute that for us
        Python code taken from https://uniswapv3book.com

        ```py
        import math

        q96 = 2**96

        def tick_to_price(t):
            return 1.0001**t

        def price_to_sqrtp(p):
            return int(math.sqrt(p) * q96)

        sqrtp_low = price_to_sqrtp(tick_to_price(-60))
        sqrtp_cur = price_to_sqrtp(tick_to_price(0))
        sqrtp_upp = price_to_sqrtp(tick_to_price(60))

        def calc_amount0(liq_delta, pa, pb):
            if pa > pb:
                pa, pb = pb, pa
            return int(liq_delta * q96 * (pb - pa) / pa / pb)

        def calc_amount1(liq_delta, pa, pb):
            if pa > pb:
                pa, pb = pb, pa
            return int(liq_delta * (pb - pa) / q96)

        one_ether = 10 ** 18
        liq = 1 * one_ether
        eth_amount = calc_amount0(liq, sqrtp_upp, sqrtp_cur)
        token_amount = calc_amount1(liq, sqrtp_low, sqrtp_cur)

        print(dict({
        'eth_amount': eth_amount,
        'eth_amount_readable': eth_amount / 10**18,
        'token_amount': token_amount,
        'token_amount_readable': token_amount / 10**18,
        }))
        ```

        {'eth_amount': 2995354955910434, 'eth_amount_readable': 0.002995354955910434, 'token_amount': 2995354955910412, 'token_amount_readable': 0.002995354955910412}

        Therefore, Δx = 0.002995354955910434 ETH and Δy = 0.002995354955910434 Tokens

        NOTE: Python and Solidity handle precision a bit differently, so these are rough amounts. Slight loss of precision is to be expected.

        */

    function test_addLiquidityAndSwap() public {
    }

    function test_addLiquidityAndSwapWithReferral() public {
    }
}
