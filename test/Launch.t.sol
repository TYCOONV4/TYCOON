// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {TycoonToken} from "../src/TycoonToken.sol";
import {TycoonHook} from "../src/TycoonHook.sol";
import {ProtectedNativeInitializerV1, IProtectedLaunchHookV1, ILaunchUsdFeedV1} from "../src/launch-protection/ProtectedNativeInitializerV1.sol";
import {LaunchProtectionModuleV1} from "../src/launch-protection/LaunchProtectionModuleV1.sol";
import {ProtectedLaunchTokenV1} from "../src/launch-protection/ProtectedLaunchTokenV1.sol";
import {EthereumNativeFeeVaultV3} from "../src/ethereum-native30-v3/EthereumNativeFeeVaultV3.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Full launch on a mainnet fork: the launch-protection initializer with the live ETH/USD feed, our token
///         and hook, the launch buy, the protection window through the pinned router, trades, the board.
///         Run with ETH_RPC set.
contract LaunchTest is Test {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant ROUTER = 0xd92A36B0000531EF3063dEd4De20A0783308446C;
    ILaunchUsdFeedV1 constant FEED = ILaunchUsdFeedV1(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    uint256 constant PAWN_SLOT = 17; // forge inspect TycoonHook storage-layout
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant LAUNCH_VALUE = 0.05 ether;
    uint256 constant TARGET_FDV_USD = 17_000;

    // fresh addresses: well-known test keys carry EIP-7702 delegations to sweepers on mainnet
    address dev = address(uint160(uint256(keccak256("tycoon dev 2026"))));
    address team = address(uint160(uint256(keccak256("tycoon team 2026"))));
    address alice = address(uint160(uint256(keccak256("tycoon alice 2026"))));
    address bob = address(uint160(uint256(keccak256("tycoon bob 2026"))));
    address[6] exempt;

    ProtectedNativeInitializerV1 init;
    TycoonToken token;
    TycoonHook hook;
    LaunchProtectionModuleV1 module;
    EthereumNativeFeeVaultV3 feeVault;
    EthereumNativeFeeVaultV3 taxVault;
    PoolSwapTest router;
    PoolKey key;
    int24 openTick;
    uint160 sqrtOpen;
    uint256 startedAt;
    uint256 devTokens;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"));
        for (uint256 i = 0; i < 6; ++i) {
            exempt[i] = address(uint160(uint256(keccak256(abi.encode("tycoon exempt 2026", i)))));
        }
        address[4] memory fresh = [dev, team, alice, bob];
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(fresh[i].code.length, 0, "test address carries code");
            assertEq(fresh[i].balance, 0, "test address not empty");
        }
        // the feed must be fresh for the initializer; the fork may sit right before a heartbeat
        (,,, uint256 updated,) = FEED.latestRoundData();
        if (vm.getBlockTimestamp() > updated + 50 minutes) vm.warp(updated + 1);

        // the launch graph: initializer -> token -> hook, deployed by this test, which plays the graph factory
        init = new ProtectedNativeInitializerV1(PM, address(this), FEED, address(FEED).codehash);
        token = new TycoonToken("Tycoon", "TYCOON", SUPPLY, address(init), address(PM));
        openTick = _tickForFdv(TARGET_FDV_USD);
        sqrtOpen = TickMath.getSqrtPriceAtTick(openTick);
        TycoonHook.PoolConfig memory config = TycoonHook.PoolConfig({
            token: address(token),
            lpFee: 0,
            tickSpacing: 60,
            initialSqrtPriceX96: sqrtOpen,
            initializer: address(init),
            creatorFeeRecipient: team,
            creatorBuyFeeBps: 320,
            creatorSellFeeBps: 320,
            module: address(0),
            maxModuleLpFeePips: 0
        });
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(flags, 0x20CC, "mask");
        bytes memory args = abi.encode(PM, config, dev, ROUTER, ROUTER.codehash, exempt);
        bytes32 salt = _mine(flags, abi.encodePacked(type(TycoonHook).creationCode, args));
        hook = new TycoonHook{salt: salt}(PM, config, dev, ROUTER, ROUTER.codehash, exempt);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, flags, "hook address flags");
        module = LaunchProtectionModuleV1(hook.module());
        feeVault = hook.feeVault();
        taxVault = hook.openingTaxVault();
        key = hook.poolKey();

        // the atomic launch: seed, lock, start, buy for the developer
        vm.deal(address(this), 10 ether);
        init.initialize{value: LAUNCH_VALUE}(IProtectedLaunchHookV1(address(hook)), token, openTick, dev, 1);
        startedAt = vm.getBlockTimestamp();
        devTokens = token.balanceOf(dev);

        router = new PoolSwapTest(PM);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        for (uint256 i = 0; i < 6; ++i) vm.deal(exempt[i], 10 ether);
    }

    // ---------------- helpers ----------------

    /// @dev The highest tick (a multiple of 60) whose opening FDV, by the initializer's own formula, reaches `usd`.
    function _tickForFdv(uint256 usd) internal view returns (int24 tick) {
        (, int256 answer,,,) = FEED.latestRoundData();
        uint8 dec = FEED.decimals();
        for (tick = 200_040; tick > -887_220; tick -= 60) {
            uint160 sp = TickMath.getSqrtPriceAtTick(tick);
            uint256 nativeValue = FullMath.mulDiv(uint256(1) << 192, SUPPLY, uint256(sp) * sp);
            uint256 fdv = FullMath.mulDiv(nativeValue, uint256(answer), 1 ether * 10 ** dec);
            if (fdv >= usd) return tick;
        }
        revert("no tick");
    }

    function _mine(uint160 flags, bytes memory initCode) internal view returns (bytes32 salt) {
        bytes32 h = keccak256(initCode);
        for (uint256 i = 0; i < 200_000; ++i) {
            salt = bytes32(i);
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, h)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == flags && a.code.length == 0) return salt;
        }
        revert("no salt");
    }

    function _afterProtection() internal {
        vm.warp(startedAt + 301);
        vm.roll(vm.getBlockNumber() + 25);
    }

    function _fundTreasury() internal {
        vm.startPrank(dev);
        token.approve(address(hook), devTokens);
        hook.fundTreasury(devTokens);
        vm.stopPrank();
    }

    function _buy(address who, uint256 ethIn) internal returns (uint256 got) {
        uint256 before = token.balanceOf(who);
        vm.prank(who, who);
        router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        got = token.balanceOf(who) - before;
    }

    /// @dev A bare buy, for expectRevert: no balance reads before the swap.
    function _rawBuy(address who, uint256 ethIn) internal {
        vm.prank(who, who);
        router.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _buyExactOut(address who, uint256 tokensOut, uint256 maxEth) internal returns (uint256 spent) {
        uint256 before = who.balance;
        vm.prank(who, who);
        router.swap{value: maxEth}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: int256(tokensOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        spent = before - who.balance;
    }

    function _sell(address who, uint256 tokensIn) internal returns (uint256 ethOut) {
        uint256 before = who.balance;
        vm.startPrank(who, who);
        token.approve(address(router), tokensIn);
        router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(tokensIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        ethOut = who.balance - before;
    }

    function _sellExactOut(address who, uint256 ethOut) internal returns (uint256 tokensIn) {
        uint256 before = token.balanceOf(who);
        vm.startPrank(who, who);
        token.approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: int256(ethOut), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        tokensIn = before - token.balanceOf(who);
    }

    /// @dev A buy through the pinned Universal Router: V4_SWAP with exact-in single, settle all, take all.
    function _routerBuy(address who, uint256 ethIn) internal returns (uint256 got) {
        bytes memory actions = abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, true, uint128(ethIn), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, uint256(ethIn));
        params[2] = abi.encode(key.currency1, uint256(0));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 before = token.balanceOf(who);
        vm.prank(who, who);
        IUniversalRouter(ROUTER).execute{value: ethIn}(abi.encodePacked(uint8(0x10)), inputs, vm.getBlockTimestamp() + 60);
        got = token.balanceOf(who) - before;
    }

    /// @dev An exact-out buy through the pinned Universal Router.
    function _routerBuyExactOut(address who, uint256 tokensOut, uint256 maxEth) internal {
        bytes memory actions = abi.encodePacked(uint8(0x08), uint8(0x0c), uint8(0x0f));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, true, uint128(tokensOut), uint128(maxEth), bytes(""));
        params[1] = abi.encode(key.currency0, maxEth);
        params[2] = abi.encode(key.currency1, tokensOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(who, who);
        IUniversalRouter(ROUTER).execute{value: maxEth}(abi.encodePacked(uint8(0x10)), inputs, vm.getBlockTimestamp() + 60);
    }

    /// @dev Put a piece on a square with a seed block one behind, so the next move is rollable.
    function _place(address who, uint8 pos) internal {
        vm.setBlockhash(vm.getBlockNumber() - 1, keccak256(abi.encode("tycoon test block", vm.getBlockNumber() - 1)));
        uint256 packed = uint256(pos) | (uint256(1) << 8) | (uint256(vm.getBlockNumber() - 1) << 16) | (uint256(vm.getBlockNumber() - 1) << 80);
        vm.store(address(hook), keccak256(abi.encode(who, PAWN_SLOT)), bytes32(packed));
    }

    function _ceil(uint256 a, uint256 num, uint256 den) internal pure returns (uint256) {
        return (a * num + den - 1) / den;
    }

    // ================= launch =================

    function test_launch() public view {
        assertTrue(init.initialized());
        assertTrue(hook.initialized());
        assertGe(init.openingFdvUsd(), 15_000, "USD floor");
        assertGe(init.openingFdvUsd(), TARGET_FDV_USD - 100, "target FDV");
        assertGt(init.lockedLiquidity(), 0);
        assertEq(token.startedAt(), startedAt);
        assertLt(token.balanceOf(address(init)), 1e9, "everything seeded, rounding dust only");
        assertGt(devTokens, 0);
        assertLe(devTokens, token.walletTokenLimit(), "launch buy inside the 2% limit");
        assertEq(token.balanceOf(address(hook)), 0, "treasury starts empty");
        assertEq(hook.treasury(), 0);
        // the launch buy paid the normal fees: 0.3% platform, 1% team through the vault, 2.2% buffered for streets
        uint256 platform = _ceil(LAUNCH_VALUE, 30, 10_000);
        uint256 creator = _ceil(LAUNCH_VALUE, 350, 10_000) - platform;
        uint256 teamFee = creator * 100 / 320;
        assertEq(feeVault.platformAccrued(), platform);
        assertEq(feeVault.creatorAccrued(), teamFee);
        assertEq(address(hook).balance, creator - teamFee);
        assertEq(hook.ethBuffer(), creator - teamFee);
        assertEq(taxVault.platformAccrued(), 0, "the developer pays no opening tax");
        (, bool played,,) = hook.pawn(dev);
        assertFalse(played, "the launch buy is not a turn");
        assertEq(hook.rosterCount(), 0);
        assertEq(address(module.token()), address(token));
        assertEq(module.developer(), dev);
        assertTrue(module.isTaxExempt(exempt[5]));
        assertFalse(module.isTaxExempt(alice));
        (,, string memory image, bytes memory extra) = token.metadata();
        assertEq(image, "https://raw.githubusercontent.com/TYCOONV4/TYCOON/main/token.jpg");
        assertEq(string(extra), "{\"v\":1,\"x\":\"https://x.com/Tycoonv4\"}");
        assertEq(token.name(), "Tycoon");
        assertEq(token.symbol(), "TYCOON");
    }

    function test_onlyInitializerOpensThePool() public {
        vm.expectRevert();
        PM.initialize(key, sqrtOpen);
    }

    function test_fundTreasury() public {
        _fundTreasury();
        assertEq(hook.treasury(), devTokens);
        assertEq(token.balanceOf(address(hook)), devTokens);
        assertEq(token.balanceOf(dev), 0, "the team ends with zero tokens");
        vm.expectRevert(TycoonHook.ZeroAmount.selector);
        hook.fundTreasury(0);
    }

    // ================= protection window =================

    function test_protectionWindow() public {
        // inside the window only the pinned router may buy
        vm.warp(startedAt + 1);
        vm.expectRevert();
        _rawBuy(alice, 0.1 ether);

        // a stranger pays the opening tax to the platform vault
        uint256 taxBefore = taxVault.platformAccrued();
        uint256 got = _routerBuy(alice, 0.1 ether);
        assertGt(got, 0);
        uint256 tax = taxVault.platformAccrued() - taxBefore;
        (,,, uint256 quotedTax) = hook.previewTradeFees(0.1 ether, false, true, alice);
        assertEq(tax, quotedTax);
        assertGt(tax, 0.09 ether, "about 99% minus the normal fee at second one");
        assertEq(hook.boughtDuringProtection(alice), got);
        (, bool played,,) = hook.pawn(alice);
        assertTrue(played, "a taxed buy is still a turn");

        // an exempt wallet pays only the normal fees
        taxBefore = taxVault.platformAccrued();
        uint256 platformBefore = feeVault.platformAccrued();
        uint256 landBefore = address(hook).balance;
        uint256 got1 = _routerBuy(exempt[0], 0.1 ether);
        assertEq(taxVault.platformAccrued(), taxBefore, "no opening tax for an exempt wallet");
        assertEq(feeVault.platformAccrued() - platformBefore, _ceil(0.1 ether, 30, 10_000));
        assertEq(address(hook).balance - landBefore, 0.0022 ether);
        assertGt(got1, got, "untaxed buy gets far more tokens");

        // the 2% buyer limit holds for exempt wallets too
        uint256 limit = token.walletTokenLimit();
        vm.expectRevert();
        _routerBuyExactOut(exempt[1], limit + 1, 5 ether);
        _routerBuyExactOut(exempt[1], limit - got1, 5 ether);
        assertEq(hook.boughtDuringProtection(exempt[1]), limit - got1);
        vm.expectRevert();
        _routerBuyExactOut(exempt[1], got1 + 1, 5 ether);

        // the 2% recipient limit is enforced by the token itself: inflow may reach the limit, not pass it
        vm.prank(exempt[0]);
        token.transfer(exempt[1], got1);
        assertEq(token.receivedDuringProtection(exempt[1]), limit);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(exempt[1], 1);
        vm.prank(exempt[1]);
        token.transfer(bob, 1 ether);
        assertEq(token.receivedDuringProtection(bob), 1 ether, "sending out does not restore the sender budget");

        // the tax decays to zero after 30 seconds, the router binding ends after 300
        vm.warp(startedAt + 31);
        (,,, uint256 lateTax) = hook.previewTradeFees(0.1 ether, false, true, alice);
        assertEq(lateTax, 0);
        vm.expectRevert();
        _rawBuy(alice, 0.01 ether);
        vm.warp(startedAt + 301);
        uint256 free = _buy(alice, 0.01 ether);
        assertGt(free, 0, "any router after the window");
    }

    // ================= fees =================

    function test_feesAllFourSwapShapes() public {
        _afterProtection();
        uint256 p0 = feeVault.platformAccrued();
        uint256 c0 = feeVault.creatorAccrued();
        uint256 l0 = address(hook).balance;

        // exact-in buy: fee on the 1 ETH paid
        _buy(alice, 1 ether);
        uint256 platform = _ceil(1 ether, 30, 10_000);
        uint256 creator = _ceil(1 ether, 350, 10_000) - platform;
        assertEq(feeVault.platformAccrued() - p0, platform);
        assertEq(feeVault.creatorAccrued() - c0, creator * 100 / 320);
        assertEq(address(hook).balance - l0, creator - creator * 100 / 320);
        assertEq(creator - creator * 100 / 320, 0.022 ether);

        // exact-in sell: fee on the ETH coming out of the pool
        p0 = feeVault.platformAccrued();
        c0 = feeVault.creatorAccrued();
        l0 = address(hook).balance;
        uint256 bal = token.balanceOf(alice);
        uint256 ethBefore = alice.balance;
        uint256 ethOut = _sell(alice, bal / 2);
        uint256 gross = ethOut + (feeVault.platformAccrued() - p0) + (feeVault.creatorAccrued() - c0) + (address(hook).balance - l0);
        assertEq(feeVault.platformAccrued() - p0, _ceil(gross, 30, 10_000));
        assertEq(alice.balance - ethBefore, ethOut);
        assertEq(address(hook).balance - l0, (_ceil(gross, 350, 10_000) - _ceil(gross, 30, 10_000)) * 220 / 320);

        // exact-out buy: fee on the ETH the pool asked for
        p0 = feeVault.platformAccrued();
        uint256 spent = _buyExactOut(bob, 10_000_000 ether, 1 ether);
        uint256 platformOut = feeVault.platformAccrued() - p0;
        (uint256 g, uint256 pf,) = hook.quoteFees(spent - _ceil(spent, 350, 10_000), true, true);
        assertApproxEqAbs(g, spent, 2);
        assertApproxEqAbs(pf, platformOut, 2);

        // exact-out sell: alice asks for exactly 0.01 ETH out, pays the fee on top in tokens
        p0 = feeVault.platformAccrued();
        ethBefore = alice.balance;
        _sellExactOut(alice, 0.01 ether);
        assertEq(alice.balance - ethBefore, 0.01 ether, "net out is exact");
        (, uint256 pfs,) = hook.quoteFees(0.01 ether, true, false);
        assertEq(feeVault.platformAccrued() - p0, pfs);

        // the vaults pay the fixed recipients, anyone may trigger
        uint256 platformOwed = feeVault.platformAccrued();
        uint256 teamOwed = feeVault.creatorAccrued();
        uint256 pb = PLATFORM.balance;
        feeVault.claimPlatform();
        assertEq(PLATFORM.balance - pb, platformOwed);
        feeVault.claimCreator();
        assertEq(team.balance, teamOwed);
        assertEq(feeVault.platformAccrued(), 0);
        assertEq(feeVault.creatorAccrued(), 0);
    }

    // ================= the board =================

    function test_moveRules() public {
        _afterProtection();
        _buy(alice, 0.005 ether);
        (, bool played,,) = hook.pawn(alice);
        assertFalse(played, "below MIN_MOVE: no turn");
        assertEq(hook.rosterCount(), 0);

        _buy(alice, 0.01 ether);
        (uint8 pos, bool played2, uint64 seed, uint64 last) = hook.pawn(alice);
        assertTrue(played2, "first turn taken");
        assertGt(pos, 0, "moved off START");
        assertEq(seed, uint64(vm.getBlockNumber()));
        assertEq(last, uint64(vm.getBlockNumber()));
        assertEq(hook.rosterCount(), 1);

        _buy(alice, 0.02 ether);
        (uint8 pos2,,,) = hook.pawn(alice);
        assertEq(pos2, pos, "one move per block");

        vm.roll(vm.getBlockNumber() + 1);
        (uint8 d1, uint8 d2, uint8 dest, bool passedStart, bool ready) = hook.previewRoll(alice);
        assertTrue(ready, "next roll is loaded from the seed block hash");
        _buy(alice, 0.01 ether);
        (uint8 pos3,,,) = hook.pawn(alice);
        assertEq(pos3, dest, "the move is the one previewed");
        uint256 mv = uint256(d1) + d2;
        if (d1 == d2) mv *= 2;
        if (dest != hook.JAIL_POS() || (pos + mv) % 30 != hook.GOTOJAIL_POS()) {
            assertEq((pos + mv) % 30, dest);
        }
        assertEq(passedStart, pos + mv >= 30 && dest != hook.JAIL_POS());

        // a sell is a turn as well
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bal = token.balanceOf(alice);
        (,, uint8 dest2,, bool ready2) = hook.previewRoll(alice);
        assertTrue(ready2);
        _sell(alice, bal / 2);
        (uint8 pos4,,,) = hook.pawn(alice);
        assertEq(pos4, dest2, "a sell moves the piece too");

        // a stale seed (older than 256 blocks) skips the turn and reloads
        vm.roll(vm.getBlockNumber() + 300);
        (,,,, bool ready3) = hook.previewRoll(alice);
        assertFalse(ready3);
        _buy(alice, 0.01 ether);
        (uint8 pos5,, uint64 seed5,) = hook.pawn(alice);
        assertEq(pos5, pos4, "turn skipped");
        assertEq(seed5, uint64(vm.getBlockNumber()), "seed reloaded");
    }

    function test_goToJail() public {
        _afterProtection();
        _buy(alice, 0.1 ether);
        // Go-to-Jail is square 22: stand on 18 and walk the blocks until the loaded roll is a 4
        bool found;
        for (uint256 i = 0; i < 400 && !found; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            _place(alice, 18);
            (,, uint8 dest, bool passed, bool ready) = hook.previewRoll(alice);
            if (ready && dest == hook.JAIL_POS() && !passed) {
                _buy(alice, 0.01 ether);
                (uint8 pos,,,) = hook.pawn(alice);
                assertEq(pos, hook.JAIL_POS(), "sent to jail");
                found = true;
            }
        }
        assertTrue(found, "no jail roll found in 400 blocks");
    }

    function test_startPayout() public {
        _fundTreasury();
        _afterProtection();
        uint256 got = _buy(alice, 0.1 ether); // alice holds all circulating supply -> capped at 1%
        assertEq(hook.circulating(), got, "circulating = alice");
        assertEq(hook.treasuryShareBps(alice), hook.TREASURY_CAP_BPS());
        uint256 k = hook.treasury();
        assertEq(k, devTokens);
        bool paid;
        for (uint256 i = 0; i < 50 && !paid; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            _place(alice, 28);
            (,, uint8 dest, bool passed, bool ready) = hook.previewRoll(alice);
            assertTrue(ready);
            if (!passed) continue; // landed on Go-to-Jail
            uint256 before = token.balanceOf(alice);
            _buy(alice, 0.01 ether);
            (uint8 pos,,,) = hook.pawn(alice);
            assertEq(pos, dest);
            uint256 bought = token.balanceOf(alice) - before;
            uint256 payout = k / 100;
            assertGt(bought, payout, "received buy + payout");
            assertEq(hook.treasury(), k - payout, "treasury paid 1%");
            paid = true;
        }
        assertTrue(paid);

        // a small holder gets its proportional share
        vm.roll(vm.getBlockNumber() + 1);
        uint256 bobGot = _buy(bob, 0.0001 ether);
        uint256 shareBps = bobGot * 10_000 / hook.circulating();
        assertLt(shareBps, 100);
        assertEq(hook.treasuryShareBps(bob), shareBps);
    }

    function test_landMarketAndRewards() public {
        _afterProtection();
        _buy(alice, 0.5 ether);
        _buy(bob, 0.5 ether);
        vm.prank(alice);
        token.approve(address(hook), type(uint256).max);
        vm.prank(bob);
        token.approve(address(hook), type(uint256).max);

        // square 1 is brown (rank 1), square 2 brown too; 28 and 29 dark blue (rank 8)
        assertEq(hook.rankOf(1), 1);
        assertEq(hook.rankOf(2), 1);
        assertEq(hook.rankOf(29), 8);
        assertEq(hook.rankOf(0), 0);
        assertEq(hook.rankOf(7), 0);

        vm.prank(alice);
        vm.expectRevert(TycoonHook.NotStandingHere.selector);
        hook.buyLand(1);
        vm.prank(alice);
        vm.expectRevert(TycoonHook.NotAStreet.selector);
        hook.buyLand(0);

        // alice buys brown 1: base 1M x 1.1; the buffered launch fees go to the first buyer
        _place(alice, 1);
        uint256 buffered = hook.ethBuffer();
        assertGt(buffered, 0);
        uint256 treasuryBefore = hook.treasury();
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        hook.buyLand(1);
        assertEq(aliceBefore - token.balanceOf(alice), 1_100_000 ether);
        assertEq(hook.tileOwner(1), alice);
        assertEq(hook.tilePrice(1), 1_000_000 ether);
        assertEq(hook.treasury() - treasuryBefore, 100_000 ether, "10% premium to the treasury");
        assertEq(hook.totalWeight(), 100, "rank 1 x 100");
        assertEq(hook.ethBuffer(), 0);
        assertEq(hook.pendingOf(alice), buffered, "first owner collects the buffer");
        vm.prank(alice);
        vm.expectRevert(TycoonHook.AlreadyOwned.selector);
        hook.buyLand(1);

        // the whole brown set: +25%
        _place(alice, 2);
        vm.prank(alice);
        hook.buyLand(2);
        assertEq(hook.totalWeight(), 250, "2 x 125");

        // a trade now pays alice 2.2% of its ETH
        uint256 pendBefore = hook.pendingOf(alice);
        _buy(bob, 1 ether);
        assertEq(hook.pendingOf(alice) - pendBefore, 0.022 ether, "all land fees to the only owner");

        // bob takes brown 1: pays 1.2M, alice gets 1.1M back, price climbs to 1.1M, the set is broken
        _place(bob, 1);
        uint256 bobBefore = token.balanceOf(bob);
        uint256 aliceTok = token.balanceOf(alice);
        vm.prank(bob);
        vm.expectRevert(TycoonHook.AlreadyOwned.selector);
        hook.buyLand(1);
        vm.prank(alice);
        vm.expectRevert(TycoonHook.NotStandingHere.selector);
        hook.overbuy(1);
        vm.prank(bob);
        hook.overbuy(1);
        assertEq(bobBefore - token.balanceOf(bob), 1_200_000 ether);
        assertEq(token.balanceOf(alice) - aliceTok, 1_100_000 ether);
        assertEq(hook.tilePrice(1), 1_100_000 ether);
        assertEq(hook.tileOwner(1), bob);
        assertEq(hook.totalWeight(), 200, "alice 100 + bob 100");
        vm.prank(bob);
        vm.expectRevert(TycoonHook.NotTakeable.selector);
        hook.overbuy(1);

        // fees now split 50/50
        uint256 a0 = hook.pendingOf(alice);
        uint256 b0 = hook.pendingOf(bob);
        _buy(alice, 1 ether);
        assertEq(hook.pendingOf(alice) - a0, 0.011 ether);
        assertEq(hook.pendingOf(bob) - b0, 0.011 ether);

        // claims pay ETH; nothing to claim twice
        uint256 owedA = hook.pendingOf(alice);
        uint256 ethA = alice.balance;
        vm.prank(alice);
        hook.claim();
        assertEq(alice.balance - ethA, owedA);
        assertEq(hook.pendingOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(TycoonHook.NothingToClaim.selector);
        hook.claim();

        // bob returns the street: 0.9 x 1.1M back, 10% to the treasury, square reset
        uint256 tBefore = hook.treasury();
        uint256 bobTok = token.balanceOf(bob);
        vm.prank(alice);
        vm.expectRevert(TycoonHook.NotYourStreet.selector);
        hook.returnLand(1);
        vm.prank(bob);
        hook.returnLand(1);
        assertEq(token.balanceOf(bob) - bobTok, 990_000 ether);
        assertEq(hook.treasury() - tBefore, 110_000 ether);
        assertEq(hook.tileOwner(1), address(0));
        assertEq(hook.tilePrice(1), 0);
        assertEq(hook.totalWeight(), 100);

        // books: the hook holds at least every locked price plus the treasury, and exactly the unclaimed ETH
        (, uint256[] memory prices,) = hook.board();
        uint256 locked;
        for (uint256 i = 0; i < prices.length; ++i) locked += prices[i];
        assertGe(token.balanceOf(address(hook)), locked + hook.treasury(), "token books");
        hook.sync(bob);
        assertGe(address(hook).balance, hook.holderPending(alice) + hook.holderPending(bob) + hook.ethBuffer(), "eth books");
        assertApproxEqAbs(address(hook).balance, hook.holderPending(alice) + hook.holderPending(bob) + hook.ethBuffer(), 10, "eth books: rounding dust only");
        (address[] memory who, uint8[] memory sq) = hook.roster(0, 10);
        assertEq(who.length, 2);
        assertEq(who[0], alice);
        assertEq(who[1], bob);
        (uint8 alicePos,,,) = hook.pawn(alice);
        assertEq(sq[0], alicePos);
    }

    function test_purgeRedistributes() public {
        _afterProtection();
        _buy(alice, 0.5 ether);
        _buy(bob, 0.5 ether);
        vm.prank(alice);
        token.approve(address(hook), type(uint256).max);
        vm.prank(bob);
        token.approve(address(hook), type(uint256).max);
        _place(alice, 1);
        vm.prank(alice);
        hook.buyLand(1); // rank 1: weight 100; alice also takes the buffered launch fees
        _place(bob, 29);
        vm.prank(bob);
        hook.buyLand(29); // rank 8: weight 800
        assertEq(hook.purgeableAt(alice), vm.getBlockTimestamp() + 24 hours);
        _buy(alice, 1 ether); // 0.022 ETH split 100:800
        uint256 aliceOwed = hook.pendingOf(alice);
        assertGt(aliceOwed, 0);

        vm.expectRevert(TycoonHook.ClaimWindowOpen.selector);
        hook.purge(alice);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        // bob claims in time: his clock restarts, nothing of his can be purged
        vm.prank(bob);
        hook.claim();
        vm.expectRevert(TycoonHook.ClaimWindowOpen.selector);
        hook.purge(bob);
        // alice never claimed: anyone moves her reward to the other owners (bob), her street stays
        uint256 purged = hook.purge(alice);
        assertEq(purged, aliceOwed);
        assertEq(hook.pendingOf(alice), 0, "nothing left for alice");
        assertEq(hook.pendingOf(bob), aliceOwed, "bob receives all of it, alice is excluded from the split");
        assertEq(hook.tileOwner(1), alice, "street untouched");
        assertEq(hook.purgeableAt(alice), vm.getBlockTimestamp() + 24 hours, "window restarted");
        vm.expectRevert(TycoonHook.ClaimWindowOpen.selector);
        hook.purge(alice);
        // a sole owner cannot be purged into an empty room
        vm.prank(bob);
        hook.returnLand(29);
        _buy(bob, 1 ether);
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1);
        vm.expectRevert(TycoonHook.NoOtherOwners.selector);
        hook.purge(alice);
        // books still balance
        hook.sync(alice);
        hook.sync(bob);
        assertGe(address(hook).balance, hook.holderPending(alice) + hook.holderPending(bob) + hook.ethBuffer(), "eth books");
        assertApproxEqAbs(address(hook).balance, hook.holderPending(alice) + hook.holderPending(bob) + hook.ethBuffer(), 10, "eth books: rounding dust only");
    }

    function test_gasOfSwap() public {
        _afterProtection();
        _buy(alice, 0.03 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice, alice);
        uint256 g = gasleft();
        router.swap{value: 0.03 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.03 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        emit log_named_uint("buy gas via test router (warm wallet, with a move)", g - gasleft());
    }
}
