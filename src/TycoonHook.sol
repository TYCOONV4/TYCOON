// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Website: https://tycoon.family/
// X:       https://x.com/Tycoonv4

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { BaseHook } from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { LaunchProtectionModuleV1 } from "./launch-protection/LaunchProtectionModuleV1.sol";
import { ProtectedLaunchTokenV1 } from "./launch-protection/ProtectedLaunchTokenV1.sol";
import { EthereumNativeFeeVaultV3 } from "./ethereum-native30-v3/EthereumNativeFeeVaultV3.sol";

/// @notice Read-only validation interface; this version requires zero LP fees and zero custom module deltas.
/// @dev Implementations must authenticate this kernel as caller. A module never executes in kernel storage.
interface IProtectedNativeFeeModuleV1 {
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        external
        view
        returns (bytes4, BeforeSwapDelta, uint24);
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) external view returns (bytes4, int128);
}

/// @title TycoonHook
/// @notice ProtectedNative30HookV1 (launch-protection v1 kernel, unchanged) carrying the Tycoon board game.
///         Every line of the protection kernel is kept; the additions are marked `TYCOON`.
///  - fees: 0.3% platform + 3.2% creator on the gross ETH leg; the creator part is split 1% team, 2.2% street owners
///  - opening tax, buyer and recipient limits, router binding, fee vaults: exactly as in the kernel
///  - a swap of at least MIN_MOVE ETH rolls 2d6 for tx.origin and walks its piece around 30 squares
///  - the dice come from the block hash of the piece's previous move: readable in advance, impossible to bend
///  - passing START pays TYCOON from the treasury in proportion to the holder's share, capped at 1% per pass
///  - the treasury starts empty and is funded by `fundTreasury` (the launch buy) and street price mark-ups
///  - streets are bought, taken over and returned in TYCOON while the piece stands on them
///  - a reward left unclaimed for 24 hours can be redistributed to the other street owners by anyone
contract TycoonHook is BaseHook {
    uint256 public constant POLICY_REVISION = 2;
    using SafeCast for uint256;
    using SafeCast for int256;
    using LPFeeLibrary for uint24;

    uint256 public immutable CHAIN_ID;
    address public immutable CANONICAL_POOL_MANAGER;
    address public constant PLATFORM_RECIPIENT = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da;
    uint16 public constant PLATFORM_FEE_BPS = 30;
    uint16 public constant FEE_DENOMINATOR = 10_000;
    bytes32 public constant FEE_PROFILE = keccak256("programmable.protected-native-fee.v1.gross-native.ceil-per-trade");

    struct PoolConfig {
        address token;
        uint24 lpFee;
        int24 tickSpacing;
        uint160 initialSqrtPriceX96;
        address initializer;
        address creatorFeeRecipient;
        uint16 creatorBuyFeeBps;
        uint16 creatorSellFeeBps;
        address module;
        uint24 maxModuleLpFeePips;
    }

    address public immutable token;
    uint24 public immutable lpFee;
    int24 public immutable tickSpacing;
    uint160 public immutable initialSqrtPriceX96;
    address public immutable initializer;
    uint16 public immutable creatorBuyFeeBps;
    uint16 public immutable creatorSellFeeBps;
    address public immutable module;
    bytes32 public immutable moduleCodeHash;
    uint24 public immutable maxModuleLpFeePips;
    EthereumNativeFeeVaultV3 public immutable feeVault;
    EthereumNativeFeeVaultV3 public immutable openingTaxVault;
    uint24 private activeOpeningTaxPpm;
    address private activeBuyer;
    mapping(address => uint256) public boughtDuringProtection;
    bool public initialized;
    bool private swapActive;
    bytes32 private activeSwap;
    uint256 private expectedNativePoolAmount;

    // ---------------- TYCOON: creator fee split ----------------
    uint16 public constant TEAM_FEE_BPS = 100; // 1.00% of the gross ETH leg, paid through the fee vault
    uint16 public constant LAND_FEE_BPS = 220; // 2.20% of the gross ETH leg, ETH held here for street owners
    uint256 private activeGross; // gross ETH of the swap in flight, for the turn

    // ---------------- TYCOON: board ----------------
    uint256 public constant MIN_MOVE = 0.01 ether; // ETH leg needed for a swap to count as a turn
    uint256 public constant N_TILES = 30;
    uint256 public constant BASE_UNIT = 1_000_000 ether; // street base price = colour rank x this
    uint256 public constant START_POS = 0;
    uint256 public constant JAIL_POS = 7;
    uint256 public constant FREE_PARK_POS = 15;
    uint256 public constant GOTOJAIL_POS = 22;
    uint256 public constant TREASURY_CAP_BPS = 100; // a START pass pays at most 1% of the treasury
    uint256 public constant CLAIM_WINDOW = 24 hours; // claim within this or the reward goes back to the other owners
    uint256 public constant BPS = 10_000;
    uint256 public constant MAG = 1e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // colour rank of every square, one byte each: 0 = corner/safe, 1 brown .. 8 dark blue
    uint256 private constant RANKS = 0x080807000707060006060500050500040404000303030002020200010100;

    // ---------------- TYCOON: street rewards (ETH) ----------------
    uint256 public accPerWeight;
    uint256 public totalWeight;
    uint256 public ethBuffer; // fees taken before any street is owned; paid to the first buyer
    mapping(address => uint256) public landWeight;
    mapping(address => uint256) public holderCheckpoint;
    mapping(address => uint256) public holderPending;
    mapping(address => uint64) public rewardClock; // starts on buy-in, refreshed only by a claim; 0 = never bought in

    // ---------------- TYCOON: streets ----------------
    mapping(uint256 => address) public tileOwner;
    mapping(uint256 => uint256) public tilePrice; // TYCOON locked in the square
    mapping(address => mapping(uint256 => uint256)) public ownedOfRank;
    uint256 public treasury; // TYCOON paid out on passing START

    // ---------------- TYCOON: pieces ----------------
    struct Pawn {
        uint8 pos;
        bool played;
        uint64 seedBlock;
        uint64 lastMoveBlock;
    }

    mapping(address => Pawn) public pawn;
    address[] private _roster;
    mapping(address => bool) private _rostered;
    uint256 private _gate;

    error InvalidConfiguration();
    error UnexpectedPool();
    error UnauthorizedInitializer();
    error UninitializedPool();
    error ReentrantSwap();
    error InvalidSwapContext();
    error PartialFillUnsupported(uint256 expected, uint256 actual);
    error UnsupportedCustomDelta();
    error InvalidModuleResponse();
    error ModuleCodeChanged();
    error InvalidDynamicFeeOverride();
    error NoTrade();
    error BuyerLimitExceeded(address buyer, uint256 attempted, uint256 limit);
    // TYCOON
    error Reentrancy();
    error NotAStreet();
    error NotStandingHere();
    error AlreadyOwned();
    error NotTakeable();
    error NotYourStreet();
    error NothingToClaim();
    error TransferFailed();
    error NothingToPurge();
    error ClaimWindowOpen();
    error NoOtherOwners();
    error ZeroAmount();

    event NativeFeesAccrued(
        bytes32 indexed poolId,
        address indexed sender,
        bool isBuy,
        uint256 grossNative,
        uint256 platformFee,
        uint256 creatorFee
    );

    event OpeningTaxAccrued(bytes32 indexed poolId, address indexed sender, uint256 grossNative, uint256 amount);

    // TYCOON
    event LandFeeTaken(bool buy, uint256 gross, uint256 amount);
    event TreasuryFunded(address indexed from, uint256 amount);
    event Moved(address indexed who, uint256 from, uint256 to, uint8 d1, uint8 d2, bool passedStart);
    event Treasury(address indexed who, uint256 amount);
    event Bought(uint256 indexed tile, address indexed owner, uint256 price);
    event Overbought(uint256 indexed tile, address indexed owner, address indexed from, uint256 paid, uint256 newPrice);
    event Returned(uint256 indexed tile, address indexed owner, uint256 refund);
    event Claimed(address indexed who, uint256 amount);
    event Purged(address indexed who, uint256 amount);

    modifier nonReentrant() {
        if (_gate != 0) revert Reentrancy();
        _gate = 1;
        _;
        _gate = 0;
    }

    constructor(
        IPoolManager manager,
        PoolConfig memory config,
        address developer,
        address router,
        bytes32 routerCodeHash,
        address[6] memory exemptWallets
    ) BaseHook(manager) {
        CHAIN_ID = block.chainid;
        CANONICAL_POOL_MANAGER = block.chainid == 1
            ? 0x000000000004444c5dc75cB358380D2e3dE08A90
            : 0x8366a39CC670B4001A1121B8F6A443A643e40951;
        if (
            (block.chainid != 1 && block.chainid != 4663) || address(manager) != CANONICAL_POOL_MANAGER
                || address(manager).code.length == 0 || config.lpFee != 0 || config.tickSpacing != 60
                || config.module != address(0) || config.creatorBuyFeeBps > 1000 || config.creatorSellFeeBps > 1000
                || config.token == address(0) || config.initializer == address(0)
                || config.creatorFeeRecipient == address(0) || config.initialSqrtPriceX96 == 0
                || config.tickSpacing <= 0 || config.maxModuleLpFeePips != 0
                || uint256(config.creatorBuyFeeBps) + PLATFORM_FEE_BPS >= FEE_DENOMINATOR
                || uint256(config.creatorSellFeeBps) + PLATFORM_FEE_BPS >= FEE_DENOMINATOR
        ) revert InvalidConfiguration();
        // TYCOON: the creator rate is the fixed team + street split on both sides
        if (
            config.creatorBuyFeeBps != TEAM_FEE_BPS + LAND_FEE_BPS || config.creatorSellFeeBps != TEAM_FEE_BPS + LAND_FEE_BPS
        ) revert InvalidConfiguration();
        config.lpFee.getInitialLPFee();
        if (
            ProtectedLaunchTokenV1(config.token).initializer() != config.initializer
                || ProtectedLaunchTokenV1(config.token).poolManager() != address(manager)
        ) {
            revert InvalidConfiguration();
        }
        token = config.token;
        lpFee = config.lpFee;
        tickSpacing = config.tickSpacing;
        initialSqrtPriceX96 = config.initialSqrtPriceX96;
        initializer = config.initializer;
        creatorBuyFeeBps = config.creatorBuyFeeBps;
        creatorSellFeeBps = config.creatorSellFeeBps;
        // Keep the normal fee vault as CREATE child 1 for canonical native-fee proof compatibility.
        feeVault = new EthereumNativeFeeVaultV3(manager, config.creatorFeeRecipient);
        LaunchProtectionModuleV1 protection = new LaunchProtectionModuleV1(
            address(this),
            ProtectedLaunchTokenV1(config.token),
            developer,
            router,
            routerCodeHash,
            config.creatorBuyFeeBps,
            exemptWallets
        );
        module = address(protection);
        moduleCodeHash = address(protection).codehash;
        maxModuleLpFeePips = 0;
        openingTaxVault = new EthereumNativeFeeVaultV3(manager, PLATFORM_RECIPIENT);
    }

    /// @dev TYCOON: the street share is taken from the PoolManager as ETH into this contract.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(Currency.wrap(address(0)), Currency.wrap(token), lpFee, tickSpacing, IHooks(address(this)));
    }

    /// @notice Quote gross native trade value and fixed-recipient fee allocations, all denominated in wei.
    /// @dev Gross includes platform and creator hook fees. Core LP fees already affect the core trade price.
    ///      Creator rates cannot reduce platform's independent ceil(gross * 30 / 10000) allocation.
    function quoteFees(uint256 amount, bool amountIsNet, bool isBuy)
        public
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee)
    {
        uint256 totalBps = PLATFORM_FEE_BPS + uint256(isBuy ? creatorBuyFeeBps : creatorSellFeeBps);
        gross =
            amountIsNet ? Math.mulDiv(amount, FEE_DENOMINATOR, FEE_DENOMINATOR - totalBps, Math.Rounding.Ceil) : amount;
        uint256 totalFee =
            amountIsNet ? gross - amount : Math.mulDiv(gross, totalBps, FEE_DENOMINATOR, Math.Rounding.Ceil);
        platformFee = Math.mulDiv(gross, PLATFORM_FEE_BPS, FEE_DENOMINATOR, Math.Rounding.Ceil);
        creatorFee = totalFee - platformFee;
    }

    function previewTradeFees(uint256 amount, bool amountIsNet, bool isBuy, address buyer)
        external
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax)
    {
        uint24 taxPpm = isBuy ? LaunchProtectionModuleV1(module).additionalTaxPpmForBuyer(buyer) : 0;
        return _quoteTradeFees(amount, amountIsNet, isBuy, taxPpm);
    }

    function _quoteTradeFees(uint256 amount, bool amountIsNet, bool isBuy, uint24 taxPpm)
        private
        view
        returns (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax)
    {
        uint256 normalPpm = (PLATFORM_FEE_BPS + uint256(isBuy ? creatorBuyFeeBps : creatorSellFeeBps)) * 100;
        uint256 totalPpm = normalPpm + taxPpm;
        if (totalPpm >= 1_000_000) revert InvalidConfiguration();
        gross = amountIsNet ? Math.mulDiv(amount, 1_000_000, 1_000_000 - totalPpm, Math.Rounding.Ceil) : amount;
        uint256 totalFee = amountIsNet ? gross - amount : Math.mulDiv(gross, totalPpm, 1_000_000, Math.Rounding.Ceil);
        uint256 normalFee = Math.mulDiv(gross, normalPpm, 1_000_000, Math.Rounding.Ceil);
        platformFee = Math.mulDiv(gross, PLATFORM_FEE_BPS, FEE_DENOMINATOR, Math.Rounding.Ceil);
        creatorFee = normalFee - platformFee;
        openingTax = totalFee - normalFee;
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160 price) internal override returns (bytes4) {
        _requirePool(key);
        if (initialized || sender != initializer || price != initialSqrtPriceX96) revert UnauthorizedInitializer();
        initialized = true;
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24 overrideFee)
    {
        _requirePool(key);
        if (!initialized) revert UninitializedPool();
        if (swapActive) revert ReentrantSwap();
        if (params.amountSpecified == 0) revert NoTrade();
        swapActive = true;
        activeSwap = keccak256(abi.encode(sender, key, params, data));
        overrideFee = _beforeModule(sender, key, params, data);
        if (params.zeroForOne && block.timestamp < ProtectedLaunchTokenV1(token).startedAt() + 300) {
            activeBuyer = LaunchProtectionModuleV1(module).protectedBuyer(sender);
        }
        activeOpeningTaxPpm = params.zeroForOne ? LaunchProtectionModuleV1(module).openingTaxPpmForSender(sender) : 0;
        bool nativeIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        if (!nativeIsSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
        uint256 nativeAmount = _absolute(params.amountSpecified);
        (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax) =
            _quoteTradeFees(nativeAmount, params.amountSpecified > 0, params.zeroForOne, activeOpeningTaxPpm);
        uint256 total = platformFee + creatorFee + openingTax;
        if (params.amountSpecified < 0 && total >= nativeAmount) revert NoTrade();
        expectedNativePoolAmount = params.amountSpecified > 0 ? gross : nativeAmount - total;
        if (expectedNativePoolAmount == 0) revert NoTrade();
        activeGross = gross; // TYCOON
        _accrue(sender, key, params.zeroForOne, gross, platformFee, creatorFee, openingTax);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(total.toInt256().toInt128(), 0), overrideFee);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) internal override returns (bytes4, int128) {
        _requirePool(key);
        if (!swapActive || activeSwap != keccak256(abi.encode(sender, key, params, data))) revert InvalidSwapContext();
        uint256 nativeAmount = _absolute(int256(delta.amount0()));
        if (nativeAmount == 0 || delta.amount1() == 0) revert NoTrade();
        bool nativeIsSpecified = params.zeroForOne == (params.amountSpecified < 0);
        uint256 total;
        if (nativeIsSpecified) {
            if (nativeAmount != expectedNativePoolAmount) {
                revert PartialFillUnsupported(expectedNativePoolAmount, nativeAmount);
            }
        } else {
            (uint256 gross, uint256 platformFee, uint256 creatorFee, uint256 openingTax) =
                _quoteTradeFees(nativeAmount, params.amountSpecified > 0, params.zeroForOne, activeOpeningTaxPpm);
            total = platformFee + creatorFee + openingTax;
            if (params.amountSpecified < 0 && total >= nativeAmount) revert NoTrade();
            activeGross = gross; // TYCOON
            _accrue(sender, key, params.zeroForOne, gross, platformFee, creatorFee, openingTax);
        }
        if (activeBuyer != address(0)) {
            if (delta.amount1() <= 0) revert NoTrade();
            uint256 bought = boughtDuringProtection[activeBuyer] + uint256(uint128(delta.amount1()));
            uint256 limit = ProtectedLaunchTokenV1(token).walletTokenLimit();
            if (bought > limit) revert BuyerLimitExceeded(activeBuyer, bought, limit);
            boughtDuringProtection[activeBuyer] = bought;
            activeBuyer = address(0);
        }
        _afterModule(sender, key, params, delta, data);
        // TYCOON: the launch buy is not a turn; every later swap of at least MIN_MOVE ETH is
        if (sender != initializer) _maybeMove(tx.origin, activeGross);
        activeGross = 0;
        expectedNativePoolAmount = 0;
        activeSwap = bytes32(0);
        activeOpeningTaxPpm = 0;
        swapActive = false;
        return (IHooks.afterSwap.selector, total.toInt256().toInt128());
    }

    function _beforeModule(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        private
        view
        returns (uint24 overrideFee)
    {
        if (module == address(0)) return 0;
        _requireModuleCode();
        (bytes4 selector, BeforeSwapDelta customDelta, uint24 fee) =
            IProtectedNativeFeeModuleV1(module).beforeSwap(sender, key, params, data);
        if (selector != IProtectedNativeFeeModuleV1.beforeSwap.selector) revert InvalidModuleResponse();
        if (BeforeSwapDelta.unwrap(customDelta) != 0) revert UnsupportedCustomDelta();
        if (fee != 0) {
            if (!lpFee.isDynamicFee() || !fee.isOverride()) revert InvalidDynamicFeeOverride();
            if (fee.removeOverrideFlagAndValidate() > maxModuleLpFeePips) revert InvalidDynamicFeeOverride();
        }
        return fee;
    }

    function _afterModule(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata data
    ) private view {
        if (module == address(0)) return;
        _requireModuleCode();
        (bytes4 selector, int128 customDelta) =
            IProtectedNativeFeeModuleV1(module).afterSwap(sender, key, params, delta, data);
        if (selector != IProtectedNativeFeeModuleV1.afterSwap.selector) revert InvalidModuleResponse();
        if (customDelta != 0) revert UnsupportedCustomDelta();
    }

    function _requireModuleCode() private view {
        if (module.codehash != moduleCodeHash) revert ModuleCodeChanged();
    }

    function _requirePool(PoolKey calldata key) private view {
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != token || key.fee != lpFee
                || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert UnexpectedPool();
    }

    /// @dev TYCOON: the creator fee is split; the team part goes through the fee vault as in the kernel, the street
    ///      part is taken as ETH into this contract and shared by weight (buffered until the first street is owned).
    function _accrue(
        address sender,
        PoolKey calldata key,
        bool isBuy,
        uint256 gross,
        uint256 platformFee,
        uint256 creatorFee,
        uint256 openingTax
    ) private {
        uint256 teamFee = Math.mulDiv(creatorFee, TEAM_FEE_BPS, TEAM_FEE_BPS + LAND_FEE_BPS);
        uint256 landFee = creatorFee - teamFee;
        uint256 total = platformFee + teamFee;
        total.toInt256().toInt128();
        poolManager.mint(address(feeVault), 0, total);
        feeVault.recordFees(platformFee, teamFee);
        emit NativeFeesAccrued(keccak256(abi.encode(key)), sender, isBuy, gross, platformFee, teamFee);
        if (landFee != 0) {
            poolManager.take(Currency.wrap(address(0)), address(this), landFee);
            if (totalWeight > 0) accPerWeight += landFee * MAG / totalWeight;
            else ethBuffer += landFee;
            emit LandFeeTaken(isBuy, gross, landFee);
        }
        if (openingTax != 0) {
            openingTax.toInt256().toInt128();
            poolManager.mint(address(openingTaxVault), 0, openingTax);
            openingTaxVault.recordFees(openingTax, 0);
            emit OpeningTaxAccrued(keccak256(abi.encode(key)), sender, gross, openingTax);
        }
    }

    function _absolute(int256 amount) private pure returns (uint256) {
        if (amount == type(int256).min) revert InvalidConfiguration();
        return uint256(amount < 0 ? -amount : amount);
    }

    // ================= TYCOON: treasury =================

    /// @notice Put TYCOON into the START treasury. Anyone may; the launch buy is meant to go here.
    function fundTreasury(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _pull(msg.sender, amount);
        treasury += amount;
        emit TreasuryFunded(msg.sender, amount);
    }

    // ================= TYCOON: the turn: dice, movement, START, jail =================

    /// @dev One move per piece per block. The first turn rolls from prevrandao; every later turn from the block hash
    ///      of the previous move. A seed older than 256 blocks is reloaded and the turn is skipped.
    function _maybeMove(address who, uint256 ethAmt) private {
        if (ethAmt < MIN_MOVE || who == address(0)) return;
        Pawn storage p = pawn[who];
        if (p.lastMoveBlock == uint64(block.number)) return;
        _register(who);
        uint256 h;
        if (!p.played) {
            p.played = true;
            h = uint256(keccak256(abi.encodePacked(who, block.prevrandao)));
        } else {
            uint256 sb = p.seedBlock;
            if (sb == 0 || block.number <= sb || block.number - sb > 256) {
                p.seedBlock = uint64(block.number);
                p.lastMoveBlock = uint64(block.number);
                return;
            }
            h = uint256(keccak256(abi.encodePacked(blockhash(sb), who)));
        }
        (uint8 d1, uint8 d2, uint8 dest, bool passedStart) = _roll(h, p.pos);
        uint256 from = p.pos;
        p.pos = dest;
        p.seedBlock = uint64(block.number);
        p.lastMoveBlock = uint64(block.number);
        if (passedStart) _payTreasury(who);
        emit Moved(who, from, dest, d1, d2, passedStart);
    }

    function _roll(uint256 h, uint256 from) private pure returns (uint8 d1, uint8 d2, uint8 dest, bool passedStart) {
        d1 = uint8(h % 6) + 1;
        d2 = uint8((h >> 8) % 6) + 1;
        uint256 mv = uint256(d1) + uint256(d2);
        if (d1 == d2) mv *= 2;
        uint256 raw = from + mv;
        passedStart = raw >= N_TILES;
        dest = uint8(raw % N_TILES);
        if (dest == GOTOJAIL_POS) {
            dest = uint8(JAIL_POS);
            passedStart = false;
        }
    }

    /// @dev Passing START pays treasury x min(holder share of circulating TYCOON, 1%).
    function _payTreasury(address who) private {
        uint256 k = treasury;
        uint256 c = circulating();
        if (k == 0 || c == 0) return;
        uint256 shareBps = ProtectedLaunchTokenV1(token).balanceOf(who) * BPS / c;
        if (shareBps > TREASURY_CAP_BPS) shareBps = TREASURY_CAP_BPS;
        uint256 payout = k * shareBps / BPS;
        if (payout == 0) return;
        treasury = k - payout;
        _send(who, payout);
        emit Treasury(who, payout);
    }

    // ================= TYCOON: the street market =================

    /// @notice Claim an empty street your piece stands on: base x 1.1 TYCOON, the base locked as its price.
    function buyLand(uint256 tileId) external nonReentrant {
        uint8 r = _rank(tileId);
        if (r == 0) revert NotAStreet();
        if (pawn[msg.sender].pos != tileId) revert NotStandingHere();
        if (tileOwner[tileId] != address(0)) revert AlreadyOwned();
        _register(msg.sender);
        uint256 base = uint256(r) * BASE_UNIT;
        uint256 cost = base + base / 10;
        _pull(msg.sender, cost);
        treasury += cost - base;
        tileOwner[tileId] = msg.sender;
        tilePrice[tileId] = base;
        _applyRank(msg.sender, r, true);
        _startClock(msg.sender);
        emit Bought(tileId, msg.sender, base);
    }

    /// @notice Take a street your piece stands on: pay 1.2 x price; the price climbs to 1.1 x and the old owner
    ///         walks away with 1.1 x.
    function overbuy(uint256 tileId) external nonReentrant {
        uint8 r = _rank(tileId);
        if (r == 0) revert NotAStreet();
        if (pawn[msg.sender].pos != tileId) revert NotStandingHere();
        address prev = tileOwner[tileId];
        if (prev == address(0) || prev == msg.sender) revert NotTakeable();
        _register(msg.sender);
        uint256 p = tilePrice[tileId];
        uint256 step = p / 10;
        uint256 newPrice = p + step;
        uint256 paid = p + step * 2;
        _pull(msg.sender, paid);
        _send(prev, newPrice);
        tilePrice[tileId] = newPrice;
        tileOwner[tileId] = msg.sender;
        _applyRank(prev, r, false);
        _applyRank(msg.sender, r, true);
        _startClock(msg.sender);
        emit Overbought(tileId, msg.sender, prev, paid, newPrice);
    }

    /// @notice Give a street back: receive 0.9 x price, 0.1 x goes to the treasury.
    function returnLand(uint256 tileId) external nonReentrant {
        if (tileOwner[tileId] != msg.sender) revert NotYourStreet();
        uint8 r = _rank(tileId);
        uint256 p = tilePrice[tileId];
        uint256 refund = p - p / 10;
        treasury += p - refund;
        tileOwner[tileId] = address(0);
        tilePrice[tileId] = 0;
        _applyRank(msg.sender, r, false);
        _send(msg.sender, refund);
        emit Returned(tileId, msg.sender, refund);
    }

    // ================= TYCOON: reward weight =================

    function _applyRank(address who, uint8 r, bool gain) private {
        _settle(who);
        uint256 oldC = _rankWeight(who, r);
        if (gain) ownedOfRank[who][r] += 1;
        else ownedOfRank[who][r] -= 1;
        uint256 newC = _rankWeight(who, r);
        uint256 oldTotal = totalWeight;
        uint256 newTotal = oldTotal - oldC + newC;
        landWeight[who] = landWeight[who] - oldC + newC;
        if (oldTotal == 0 && newTotal > 0 && ethBuffer > 0) {
            holderPending[who] += ethBuffer;
            ethBuffer = 0;
        }
        totalWeight = newTotal;
    }

    /// @dev rank x streets, +25% per street when the colour is complete.
    function _rankWeight(address who, uint8 r) private view returns (uint256) {
        uint256 c = ownedOfRank[who][r];
        if (c == 0) return 0;
        uint256 perTile = (c == _rankCount(r)) ? uint256(r) * 125 : uint256(r) * 100;
        return c * perTile;
    }

    function _settle(address who) private {
        uint256 w = landWeight[who];
        if (w > 0) {
            uint256 owedNow = w * (accPerWeight - holderCheckpoint[who]) / MAG;
            if (owedNow > 0) holderPending[who] += owedNow;
        }
        holderCheckpoint[who] = accPerWeight;
    }

    function _startClock(address who) private {
        if (rewardClock[who] == 0) rewardClock[who] = uint64(block.timestamp);
    }

    // ================= TYCOON: claims =================

    /// @notice Pull your reward ETH: your share of every fee while you have held streets.
    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = holderPending[msg.sender];
        if (amount == 0) revert NothingToClaim();
        holderPending[msg.sender] = 0;
        rewardClock[msg.sender] = uint64(block.timestamp);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit Claimed(msg.sender, amount);
    }

    /// @notice Fold an account's accrued reward into its claimable balance. Permissionless.
    function sync(address account) external {
        _settle(account);
    }

    /// @notice Redistribute a reward left unclaimed for CLAIM_WINDOW to the other street owners, by weight. Anyone
    ///         may call. The streets stay with their owner; only the unclaimed ETH moves, and the window restarts.
    function purge(address account) external returns (uint256 amount) {
        _settle(account);
        uint64 clk = rewardClock[account];
        if (clk == 0) revert NothingToPurge();
        if (block.timestamp <= uint256(clk) + CLAIM_WINDOW) revert ClaimWindowOpen();
        amount = holderPending[account];
        if (amount == 0) revert NothingToPurge();
        uint256 others = totalWeight - landWeight[account];
        if (others == 0) revert NoOtherOwners();
        holderPending[account] = 0;
        rewardClock[account] = uint64(block.timestamp);
        // credit everyone but the purged account: its checkpoint skips this increment
        accPerWeight += amount * MAG / others;
        holderCheckpoint[account] = accPerWeight;
        emit Purged(account, amount);
    }

    // ================= TYCOON: token helpers =================

    function _pull(address from, uint256 amount) private {
        if (!ProtectedLaunchTokenV1(token).transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _send(address to, uint256 amount) private {
        if (!ProtectedLaunchTokenV1(token).transfer(to, amount)) revert TransferFailed();
    }

    /// @notice TYCOON held by players: supply minus the pool, the initializer dust, this contract and the burn address.
    function circulating() public view returns (uint256) {
        ProtectedLaunchTokenV1 t = ProtectedLaunchTokenV1(token);
        return t.totalSupply() - t.balanceOf(address(poolManager)) - t.balanceOf(initializer) - t.balanceOf(address(this))
            - t.balanceOf(DEAD);
    }

    // ================= TYCOON: board layout =================

    function _rank(uint256 pos) private pure returns (uint8) {
        if (pos >= N_TILES) return 0;
        return uint8((RANKS >> (8 * pos)) & 0xff);
    }

    function _rankCount(uint8 r) private pure returns (uint256) {
        return (r == 1 || r == 8) ? 2 : 3;
    }

    function _register(address a) private {
        if (!_rostered[a]) {
            _rostered[a] = true;
            _roster.push(a);
        }
    }

    // ================= TYCOON: views =================

    function rankOf(uint256 pos) external pure returns (uint8) {
        return _rank(pos);
    }

    /// @notice Claimable reward ETH right now.
    function pendingOf(address who) external view returns (uint256 amount) {
        amount = holderPending[who];
        uint256 w = landWeight[who];
        if (w > 0) amount += w * (accPerWeight - holderCheckpoint[who]) / MAG;
    }

    /// @notice When a wallet's unclaimed reward becomes purgeable (0 = never bought a street).
    function purgeableAt(address who) external view returns (uint256) {
        uint64 clk = rewardClock[who];
        return clk == 0 ? 0 : uint256(clk) + CLAIM_WINDOW;
    }

    /// @notice Treasury share (bps, capped) a wallet would collect passing START now.
    function treasuryShareBps(address who) external view returns (uint256 shareBps) {
        uint256 c = circulating();
        if (c == 0) return 0;
        shareBps = ProtectedLaunchTokenV1(token).balanceOf(who) * BPS / c;
        if (shareBps > TREASURY_CAP_BPS) shareBps = TREASURY_CAP_BPS;
    }

    /// @notice The loaded next roll: dice, destination, START. `ready` is false until the seed block is in range.
    function previewRoll(address who) external view returns (uint8 d1, uint8 d2, uint8 dest, bool passedStart, bool ready) {
        Pawn storage p = pawn[who];
        if (!p.played) return (0, 0, 0, false, false);
        uint256 sb = p.seedBlock;
        if (sb == 0 || block.number <= sb || block.number - sb > 256) return (0, 0, 0, false, false);
        bytes32 bh = blockhash(sb);
        if (bh == bytes32(0)) return (0, 0, 0, false, false);
        (d1, d2, dest, passedStart) = _roll(uint256(keccak256(abi.encodePacked(bh, who))), p.pos);
        ready = true;
    }

    function rosterCount() external view returns (uint256) {
        return _roster.length;
    }

    /// @notice A page of players and the square each piece stands on.
    function roster(uint256 offset, uint256 limit) external view returns (address[] memory who, uint8[] memory square) {
        uint256 n = _roster.length;
        if (offset >= n) return (new address[](0), new uint8[](0));
        uint256 m = n - offset;
        if (m > limit) m = limit;
        who = new address[](m);
        square = new uint8[](m);
        for (uint256 i = 0; i < m; i++) {
            address a = _roster[offset + i];
            who[i] = a;
            square[i] = pawn[a].pos;
        }
    }

    /// @notice The whole board in one read: owner, locked price and colour rank of every square.
    function board() external view returns (address[] memory owners, uint256[] memory prices, uint8[] memory ranks) {
        owners = new address[](N_TILES);
        prices = new uint256[](N_TILES);
        ranks = new uint8[](N_TILES);
        for (uint256 i = 0; i < N_TILES; i++) {
            owners[i] = tileOwner[i];
            prices[i] = tilePrice[i];
            ranks[i] = _rank(i);
        }
    }
}
