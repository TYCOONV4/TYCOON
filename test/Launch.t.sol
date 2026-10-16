// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {MonoToken} from "../src/MonoToken.sol";
import {MonopolyHook} from "../src/MonopolyHook.sol";
import {Seeder} from "../src/Seeder.sol";

/// @notice Full launch on a mainnet fork: real PoolManager and PositionManager, our three contracts, the launch buy,
///         trades through the hook, the board. Run with ETH_RPC set.
contract LaunchTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    address constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant PAWN_SLOT = 15; // forge inspect MonopolyHook storage-layout

    // fresh addresses: well-known test keys carry EIP-7702 delegations to sweepers on mainnet
    address dev = address(uint160(uint256(keccak256("mono dev 2026"))));
    address team = address(uint160(uint256(keccak256("mono team 2026"))));
    address alice = address(uint160(uint256(keccak256("mono alice 2026"))));
    address bob = address(uint160(uint256(keccak256("mono bob 2026"))));

    MonoToken token;
    MonopolyHook hook;
    Seeder seeder;
    PoolSwapTest router;
    PoolKey key;

    // 1e6 tokens per ETH -> sqrt(1e6) = 1000; at 1B supply that is a 1000 ETH FDV, fine for the fee math here
    uint160 constant SQRT_OPEN = 79228162514264337593543950336 * 1000;
    uint256 constant BUY_ETH = 0.035 ether;
    uint256 constant LAUNCH_VALUE = 0.05 ether;
    int24 openTick;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC"));
        address[4] memory fresh = [dev, team, alice, bob];
        for (uint256 i = 0; i < 4; ++i) {
            assertEq(fresh[i].code.length, 0, "test address carries code");
            assertEq(fresh[i].balance, 0, "test address not empty");
        }

        // the launch graph: seeder -> token -> hook, deployed by this test, which plays the graph factory
        seeder = new Seeder(dev, POSM, address(this));
        token = new MonoToken(address(seeder));
        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        assertEq(flags, 0x20CC, "mask");
        bytes memory args = abi.encode(PM, address(token), address(seeder), PLATFORM, team);
        bytes32 salt = _mine(flags, abi.encodePacked(type(MonopolyHook).creationCode, args));
        hook = new MonopolyHook{salt: salt}(PM, address(token), address(seeder), PLATFORM, team);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, flags, "hook address flags");
        key = hook.poolKey();

        router = new PoolSwapTest(PM);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 10 ether);
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

    function _ignite() internal returns (uint256 mainId) {
        openTick = TickMath.getTickAtSqrtPrice(SQRT_OPEN);
        Seeder.IgniteParams memory p = Seeder.IgniteParams({
            sqrtPriceX96: SQRT_OPEN,
            tickLower: -30_000,
            tickUpper: openTick,
            minTokensOut: 1,
            buyEth: BUY_ETH
        });
        mainId = seeder.ignite{value: LAUNCH_VALUE}(address(token), address(hook), p);
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

    /// @dev Put a piece on a square with a seed block one behind, so the next move is rollable.
    function _place(address who, uint8 pos) internal {
        vm.setBlockhash(block.number - 1, keccak256(abi.encode("mono test block", block.number - 1)));
        uint256 packed = uint256(pos) | (uint256(1) << 8) | (uint256(block.number - 1) << 16) | (uint256(block.number - 1) << 80);
        vm.store(address(hook), keccak256(abi.encode(who, PAWN_SLOT)), bytes32(packed));
    }

    function _fee(uint256 gross, uint24 pips) internal pure returns (uint256) {
        return gross * pips / 1_000_000;
    }

    // ================= launch =================

    function test_ignite() public {
        uint256 mainId = _ignite();
        assertTrue(seeder.ignited());
        assertEq(hook.launchBlock(), uint64(block.number));
        assertEq(IERC721(address(POSM)).ownerOf(mainId), DEAD);
        assertEq(IERC721(address(POSM)).ownerOf(mainId + 1), DEAD);
        assertEq(token.balanceOf(address(seeder)), 0);
        assertEq(token.balanceOf(dev), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(hook)), hook.TREASURY_SUPPLY(), "treasury held by the hook");
        assertEq(hook.treasury(), hook.TREASURY_SUPPLY(), "treasury booked");
        assertEq(token.balanceOf(address(PM)) + hook.treasury(), token.totalSupply(), "pool holds every other token");
        assertLt(token.totalSupply(), token.SUPPLY(), "leftover was burned");
        // the launch buy paid the normal fee on 0.035 ETH
        assertEq(hook.owed(PLATFORM), _fee(BUY_ETH, 3_000), "platform 0.3%");
        assertEq(hook.owed(team), _fee(BUY_ETH, 10_000), "team 1%");
        assertEq(hook.ethBuffer(), _fee(BUY_ETH, 22_000), "land share buffered");
        assertEq(address(hook).balance, hook.ethBuffer(), "land ETH on the hook");
        assertEq(hook.swapCount(), 1);
        assertEq(hook.rosterCount(), 0, "the launch buy moves no piece");
        assertEq(token.name(), "Monopoly");
        assertEq(token.symbol(), "MONO");
        (string memory d, string memory w, string memory img, bytes memory extra) = token.metadata();
        assertGt(bytes(d).length, 0);
        assertGt(bytes(w).length, 0);
        assertGt(bytes(img).length, 0);
        assertGt(extra.length, 0);
        assertGt(bytes(token.tokenURI()).length, 0);
        emit log_named_uint("tokens burned", token.SUPPLY() - token.totalSupply());
    }

    function test_onlySeederOpensOnePool() public {
        _ignite();
        vm.expectRevert();
        PM.initialize(key, SQRT_OPEN);
        PoolKey memory other = key;
        other.tickSpacing = 60;
        vm.expectRevert();
        PM.initialize(other, SQRT_OPEN);
        vm.expectRevert(Seeder.AlreadyIgnited.selector);
        seeder.ignite{value: LAUNCH_VALUE}(
            address(token), address(hook), Seeder.IgniteParams(SQRT_OPEN, -30_000, openTick, 1, BUY_ETH)
        );
    }

    // ================= fees =================

    function test_feesAllFourSwapShapes() public {
        _ignite();
        vm.roll(block.number + 11); // past the launch guard
        uint256 p0 = hook.owed(PLATFORM);
        uint256 t0 = hook.owed(team);
        uint256 b0 = hook.ethBuffer();

        // exact-in buy: fee on the 1 ETH paid
        uint256 got = _buy(alice, 1 ether);
        assertGt(got, 0);
        assertEq(hook.owed(PLATFORM) - p0, 0.003 ether, "platform 0.3%");
        assertEq(hook.owed(team) - t0, 0.01 ether, "team 1%");
        assertEq(hook.ethBuffer() - b0, 0.022 ether, "land 2.2%");
        assertEq(PM.balanceOf(address(hook), 0), hook.owed(PLATFORM) + hook.owed(team), "claims back every owed wei");

        // exact-in sell: fee on the ETH coming out
        uint256 b1 = hook.ethBuffer();
        uint256 ethOut = _sell(alice, got / 2);
        uint256 landOnSell = hook.ethBuffer() - b1;
        // gross = ethOut + fee, land = 2.2% of gross
        assertApproxEqRel(landOnSell, (ethOut + landOnSell * 35 / 22) * 22 / 1000, 1e14, "sell fee on gross ETH");

        // exact-out buy: fee on the ETH input the pool asked for
        uint256 b2 = hook.ethBuffer();
        uint256 spent = _buyExactOut(bob, 100_000 ether, 1 ether);
        uint256 landOnExactOut = hook.ethBuffer() - b2;
        assertApproxEqRel(landOnExactOut, spent * 22 / 1000, 1e14, "exact-out buy fee on gross");

        // exact-out sell: alice asks for exactly 0.01 ETH out, pays the fee on top in tokens
        uint256 ethBefore = alice.balance;
        uint256 b3 = hook.ethBuffer();
        _sellExactOut(alice, 0.01 ether);
        assertEq(alice.balance - ethBefore, 0.01 ether, "exact-out sell pays exactly what was asked");
        uint256 landOnExactOutSell = hook.ethBuffer() - b3;
        // gross = net / (1 - 0.035)
        uint256 net = 0.01 ether;
        uint256 gross = net * 1_000_000 / (1_000_000 - 35_000);
        assertApproxEqAbs(landOnExactOutSell, gross * 22 / 1000, 1e6, "exact-out sell fee on gross");

        // tills pay out
        uint256 platformBefore = PLATFORM.balance;
        uint256 owedPlatform = hook.owed(PLATFORM);
        hook.collect(PLATFORM);
        assertEq(PLATFORM.balance - platformBefore, owedPlatform, "platform paid in ETH");
        uint256 teamBefore = team.balance;
        uint256 owedTeam = hook.owed(team);
        hook.collect(team);
        assertEq(team.balance - teamBefore, owedTeam, "team paid in ETH");
        assertEq(PM.balanceOf(address(hook), 0), 0, "no claims left");
        vm.expectRevert(MonopolyHook.NothingToCollect.selector);
        hook.collect(team);
        vm.expectRevert(MonopolyHook.UnknownRecipient.selector);
        hook.collect(bob);
    }

    // ================= launch guard =================

    function test_launchGuardBySwaps() public {
        _ignite(); // swap 0: the launch buy, exempt
        uint256 limit = hook.LAUNCH_MAX_BUY();
        assertEq(limit, token.SUPPLY() / 50, "2% of the supply");
        // at 1e6 tokens per ETH: 25 ETH is above 2%, 15 ETH below
        vm.deal(bob, 1000 ether);
        vm.prank(bob, bob);
        vm.expectRevert();
        router.swap{value: 25 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -25 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 got = _buy(bob, 15 ether);
        assertLe(got, limit, "a buy under the cap goes through");
        _sell(bob, got); // sells are never capped
        for (uint256 i = 0; i < 18; ++i) _buy(alice, 0.001 ether);
        assertEq(hook.swapCount(), 21);
        uint256 big = _buy(bob, 25 ether);
        assertGt(big, limit, "guard is over after 20 swaps");
    }

    function test_launchGuardByBlocks() public {
        _ignite();
        uint256 limit = hook.LAUNCH_MAX_BUY();
        vm.deal(bob, 1000 ether);
        vm.roll(block.number + 10);
        vm.prank(bob, bob);
        vm.expectRevert();
        router.swap{value: 25 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -25 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.roll(block.number + 1);
        uint256 big = _buy(bob, 25 ether);
        assertGt(big, limit, "guard is over after 10 blocks");
    }

    function test_exactOutBuyFitsTheGuard() public {
        _ignite();
        uint256 spent = _buyExactOut(bob, 19_900_000 ether, 50 ether);
        assertEq(token.balanceOf(bob), 19_900_000 ether);
        assertGt(spent, 0);
    }

    // ================= the board =================

    function test_moveRules() public {
        _ignite();
        vm.roll(block.number + 11);
        _buy(alice, 0.005 ether);
        (, bool played,,) = hook.pawn(alice);
        assertFalse(played, "below MIN_MOVE: no turn");
        assertEq(hook.rosterCount(), 0);

        _buy(alice, 0.01 ether);
        (uint8 pos, bool played2, uint64 seed, uint64 last) = hook.pawn(alice);
        assertTrue(played2, "first turn taken");
        assertGt(pos, 0, "moved off START");
        assertEq(seed, uint64(block.number));
        assertEq(last, uint64(block.number));
        assertEq(hook.rosterCount(), 1);

        _buy(alice, 0.02 ether);
        (uint8 pos2,,,) = hook.pawn(alice);
        assertEq(pos2, pos, "one move per block");

        vm.roll(block.number + 1);
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
        vm.roll(block.number + 1);
        uint256 bal = token.balanceOf(alice);
        (,, uint8 dest2,, bool ready2) = hook.previewRoll(alice);
        assertTrue(ready2);
        _sell(alice, bal / 2);
        (uint8 pos4,,,) = hook.pawn(alice);
        assertEq(pos4, dest2, "a sell moves the piece too");

        // a stale seed (older than 256 blocks) skips the turn and reloads
        vm.roll(block.number + 300);
        (,,,, bool ready3) = hook.previewRoll(alice);
        assertFalse(ready3);
        _buy(alice, 0.01 ether);
        (uint8 pos5,, uint64 seed5,) = hook.pawn(alice);
        assertEq(pos5, pos4, "turn skipped");
        assertEq(seed5, uint64(block.number), "seed reloaded");
    }

    function test_goToJail() public {
        _ignite();
        vm.roll(block.number + 11);
        _buy(alice, 1 ether);
        // Go-to-Jail is square 22: stand on 18 and walk the blocks until the loaded roll is a 4
        bool found;
        for (uint256 i = 0; i < 400 && !found; ++i) {
            vm.roll(block.number + 1);
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
        _ignite();
        vm.roll(block.number + 11);
        uint256 got = _buy(alice, 1 ether); // alice holds all circulating supply -> capped at 1%
        assertEq(hook.circulating(), got, "circulating = alice");
        assertEq(hook.treasuryShareBps(alice), hook.TREASURY_CAP_BPS());
        uint256 k = hook.treasury();
        bool paid;
        for (uint256 i = 0; i < 50 && !paid; ++i) {
            vm.roll(block.number + 1);
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
        vm.roll(block.number + 1);
        uint256 bobGot = _buy(bob, 0.01 ether);
        uint256 shareBps = bobGot * 10_000 / hook.circulating();
        assertLt(shareBps, 100);
        assertEq(hook.treasuryShareBps(bob), shareBps);
    }

    function test_landMarketAndRewards() public {
        _ignite();
        vm.roll(block.number + 11);
        _buy(alice, 5 ether);
        _buy(bob, 5 ether);
        vm.startPrank(alice);
        token.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        token.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // square 1 is brown (rank 1), square 2 brown too; 28 and 29 dark blue (rank 8)
        assertEq(hook.rankOf(1), 1);
        assertEq(hook.rankOf(2), 1);
        assertEq(hook.rankOf(29), 8);
        assertEq(hook.rankOf(0), 0);
        assertEq(hook.rankOf(7), 0);

        vm.prank(alice);
        vm.expectRevert(MonopolyHook.NotStandingHere.selector);
        hook.buyLand(1);
        vm.prank(alice);
        vm.expectRevert(MonopolyHook.NotAStreet.selector);
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
        vm.expectRevert(MonopolyHook.AlreadyOwned.selector);
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
        vm.expectRevert(MonopolyHook.AlreadyOwned.selector);
        hook.buyLand(1);
        vm.prank(alice);
        vm.expectRevert(MonopolyHook.NotStandingHere.selector);
        hook.overbuy(1);
        vm.prank(bob);
        hook.overbuy(1);
        assertEq(bobBefore - token.balanceOf(bob), 1_200_000 ether);
        assertEq(token.balanceOf(alice) - aliceTok, 1_100_000 ether);
        assertEq(hook.tilePrice(1), 1_100_000 ether);
        assertEq(hook.tileOwner(1), bob);
        assertEq(hook.totalWeight(), 200, "alice 100 + bob 100");
        vm.prank(bob);
        vm.expectRevert(MonopolyHook.NotTakeable.selector);
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
        vm.expectRevert(MonopolyHook.NothingToClaim.selector);
        hook.claim();

        // bob returns the street: 0.9 x 1.1M back, 10% to the treasury, square reset
        uint256 tBefore = hook.treasury();
        uint256 bobTok = token.balanceOf(bob);
        vm.prank(alice);
        vm.expectRevert(MonopolyHook.NotYourStreet.selector);
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
        _ignite();
        vm.roll(block.number + 11);
        _buy(alice, 5 ether);
        _buy(bob, 12 ether); // rank 8 costs 8.8M MONO
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
        assertEq(hook.purgeableAt(alice), block.timestamp + 24 hours);
        _buy(alice, 1 ether); // 0.022 ETH split 100:800
        uint256 aliceOwed = hook.pendingOf(alice);
        assertGt(aliceOwed, 0);

        vm.expectRevert(MonopolyHook.ClaimWindowOpen.selector);
        hook.purge(alice);
        vm.warp(block.timestamp + 24 hours + 1);
        // bob claims in time: his clock restarts, nothing of his can be purged
        vm.prank(bob);
        hook.claim();
        vm.expectRevert(MonopolyHook.ClaimWindowOpen.selector);
        hook.purge(bob);
        // alice never claimed: anyone moves her reward to the other owners (bob), her street stays
        uint256 purged = hook.purge(alice);
        assertEq(purged, aliceOwed);
        assertEq(hook.pendingOf(alice), 0, "nothing left for alice");
        assertEq(hook.pendingOf(bob), aliceOwed, "bob receives all of it, alice is excluded from the split");
        assertEq(hook.tileOwner(1), alice, "street untouched");
        assertEq(hook.purgeableAt(alice), block.timestamp + 24 hours, "window restarted");
        vm.expectRevert(MonopolyHook.ClaimWindowOpen.selector);
        hook.purge(alice);
        // a sole owner cannot be purged into an empty room
        vm.prank(bob);
        hook.returnLand(29);
        _buy(bob, 1 ether);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.expectRevert(MonopolyHook.NoOtherOwners.selector);
        hook.purge(alice);
        // books still balance
        hook.sync(alice);
        hook.sync(bob);
        assertGe(address(hook).balance, hook.holderPending(alice) + hook.holderPending(bob) + hook.ethBuffer(), "eth books");
        assertApproxEqAbs(address(hook).balance, hook.holderPending(alice) + hook.holderPending(bob) + hook.ethBuffer(), 10, "eth books: rounding dust only");
    }

    function test_gasOfSwap() public {
        _ignite();
        vm.roll(block.number + 11);
        _buy(alice, 0.3 ether);
        vm.roll(block.number + 1);
        vm.prank(alice, alice);
        uint256 g = gasleft();
        router.swap{value: 0.3 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.3 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        emit log_named_uint("buy gas via test router (warm wallet, with a move)", g - gasleft());
    }
}
