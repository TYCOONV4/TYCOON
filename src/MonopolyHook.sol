// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Website: <fill in before deploy>
// X:       <fill in before deploy>

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FeeCalc} from "./libraries/FeeCalc.sol";
import {IMonoToken} from "./interfaces/IMono.sol";

/// @title MonopolyHook
/// @notice The one permanent hook of the MONO/ETH pool and the board game itself. Immutable, no owner.
///  - every swap pays 3.5% of its ETH leg: 0.3% platform, 1% team, 2.2% to street owners by colour weight
///  - a swap of at least MIN_MOVE ETH rolls 2d6 for tx.origin and walks its piece around 30 squares
///  - the dice come from the block hash of the piece's previous move: readable in advance, impossible to bend
///  - passing START pays MONO from the treasury (10% of supply) in proportion to the holder's share, capped
///  - streets are bought, taken over and returned in MONO while the piece stands on them
///  - a reward left unclaimed for 24 hours can be redistributed to the other street owners by anyone
///  - launch guard: for the first 20 swaps after the launch buy, within 10 blocks, one buy takes at most 2% of supply
contract MonopolyHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    // ---------------- fees (pips, 1e-6) ----------------
    uint24 public constant PLATFORM_FEE = 3_000; // 0.30%
    uint24 public constant TEAM_FEE = 10_000; // 1.00%
    uint24 public constant LAND_FEE = 22_000; // 2.20%
    uint24 public constant TOTAL_FEE = PLATFORM_FEE + TEAM_FEE + LAND_FEE;
    uint256 private constant ETH_ID = 0;

    // ---------------- launch ----------------
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant TREASURY_SUPPLY = 100_000_000 ether; // 10%: the START treasury
    uint256 public constant LAUNCH_GUARD_SWAPS = 20;
    uint256 public constant LAUNCH_GUARD_BLOCKS = 10;
    uint256 public constant LAUNCH_MAX_BUY = 20_000_000 ether; // 2%

    // ---------------- board ----------------
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

    // ---------------- wiring ----------------
    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable seeder;
    address public immutable platformRecipient;
    address public immutable teamRecipient;

    // ---------------- pool ----------------
    PoolId public poolId;
    uint64 public launchBlock;
    uint64 public launchTime;
    uint256 public swapCount; // 0 = the launch buy
    mapping(address recipient => uint256 wei_) public owed; // ETH claims for the platform and the team

    // ---------------- street rewards (ETH) ----------------
    uint256 public accPerWeight;
    uint256 public totalWeight;
    uint256 public ethBuffer; // fees taken before any street is owned; paid to the first buyer
    mapping(address => uint256) public landWeight;
    mapping(address => uint256) public holderCheckpoint;
    mapping(address => uint256) public holderPending;
    mapping(address => uint64) public rewardClock; // starts on buy-in, refreshed only by a claim; 0 = never bought in

    // ---------------- streets ----------------
    mapping(uint256 => address) public tileOwner;
    mapping(uint256 => uint256) public tilePrice; // MONO locked in the square
    mapping(address => mapping(uint256 => uint256)) public ownedOfRank;
    uint256 public treasury; // MONO paid out on passing START

    // ---------------- pieces ----------------
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

    error NotPoolManager();
    error HookNotImplemented();
    error WrongPool();
    error NotSeeder();
    error PartialNativeFill();
    error ZeroAddress();
    error NothingToCollect();
    error UnknownRecipient();
    error LaunchBuyTooLarge();
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

    event FeeTaken(bool buy, uint256 gross, uint256 platform, uint256 team, uint256 land);
    event Collected(address indexed recipient, uint256 amount);
    event Moved(address indexed who, uint256 from, uint256 to, uint8 d1, uint8 d2, bool passedStart);
    event Treasury(address indexed who, uint256 amount);
    event Bought(uint256 indexed tile, address indexed owner, uint256 price);
    event Overbought(uint256 indexed tile, address indexed owner, address indexed from, uint256 paid, uint256 newPrice);
    event Returned(uint256 indexed tile, address indexed owner, uint256 refund);
    event Claimed(address indexed who, uint256 amount);
    event Purged(address indexed who, uint256 amount);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (_gate != 0) revert Reentrancy();
        _gate = 1;
        _;
        _gate = 0;
    }

    constructor(IPoolManager poolManager_, address token_, address seeder_, address platformRecipient_, address teamRecipient_) {
        if (token_ == address(0) || seeder_ == address(0) || platformRecipient_ == address(0) || teamRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        token = token_;
        seeder = seeder_;
        platformRecipient = platformRecipient_;
        teamRecipient = teamRecipient_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    receive() external payable onlyPoolManager {}

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(token),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: IHooks(address(this))
        });
    }

    // ================= initialize =================

    /// @dev One pool, opened once by the seeder. The MONO already sent here becomes the START treasury.
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != seeder) revert NotSeeder();
        if (
            PoolId.unwrap(poolId) != 0 || Currency.unwrap(key.currency0) != address(0)
                || Currency.unwrap(key.currency1) != token || key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || key.tickSpacing != 1
        ) revert WrongPool();
        poolId = key.toId();
        launchBlock = uint64(block.number);
        launchTime = uint64(block.timestamp);
        treasury = IMonoToken(token).balanceOf(address(this));
        return IHooks.beforeInitialize.selector;
    }

    // ================= swap =================

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
        uint256 fee;
        if (_nativeSpecified(params)) {
            (uint256 gross, uint256 f) = _feeOnSpecified(params);
            fee = f;
            _accrue(params.zeroForOne, gross, fee);
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool buy = params.zeroForOne;
        uint256 ethAmount = delta.amount0() < 0 ? uint256(-int256(delta.amount0())) : uint256(int256(delta.amount0()));
        uint256 ethGross;
        int128 hookFee;
        if (_nativeSpecified(params)) {
            // the pool must have moved exactly the ETH the fee was computed on
            (uint256 g, uint256 f) = _feeOnSpecified(params);
            if (ethAmount != (params.amountSpecified < 0 ? g - f : g)) revert PartialNativeFill();
            ethGross = g;
        } else {
            bool exactIn = params.amountSpecified < 0;
            uint256 fee = exactIn ? FeeCalc.onGross(ethAmount, TOTAL_FEE) : FeeCalc.onNet(ethAmount, TOTAL_FEE);
            ethGross = exactIn ? ethAmount : ethAmount + fee;
            _accrue(buy, ethGross, fee);
            hookFee = fee.toInt128();
        }

        uint256 count = swapCount++;
        if (buy && count >= 1 && count <= LAUNCH_GUARD_SWAPS && block.number <= launchBlock + LAUNCH_GUARD_BLOCKS) {
            uint256 tokenAmount = delta.amount1() < 0 ? uint256(-int256(delta.amount1())) : uint256(int256(delta.amount1()));
            if (tokenAmount > LAUNCH_MAX_BUY) revert LaunchBuyTooLarge();
        }
        if (count != 0) _maybeMove(tx.origin, ethGross);
        return (IHooks.afterSwap.selector, hookFee);
    }

    /// @dev ETH (currency0) is the specified side iff exactInput == zeroForOne.
    function _nativeSpecified(SwapParams calldata p) private pure returns (bool) {
        return (p.amountSpecified < 0) == p.zeroForOne;
    }

    function _feeOnSpecified(SwapParams calldata p) private pure returns (uint256 gross, uint256 fee) {
        bool exactIn = p.amountSpecified < 0;
        uint256 requested = exactIn ? uint256(-p.amountSpecified) : uint256(p.amountSpecified);
        fee = exactIn ? FeeCalc.onGross(requested, TOTAL_FEE) : FeeCalc.onNet(requested, TOTAL_FEE);
        gross = exactIn ? requested : requested + fee;
    }

    /// @dev Split the fee: claims for the platform and the team, ETH into the street owners' pot.
    function _accrue(bool buy, uint256 gross, uint256 fee) private {
        if (fee == 0) return;
        uint256 platform = FeeCalc.share(gross, fee, PLATFORM_FEE);
        uint256 team = FeeCalc.share(gross, fee, TEAM_FEE);
        uint256 land = fee - platform - team;
        if (platform != 0) _credit(platformRecipient, platform);
        if (team != 0) _credit(teamRecipient, team);
        if (land != 0) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), land);
            if (totalWeight > 0) accPerWeight += land * MAG / totalWeight;
            else ethBuffer += land;
        }
        emit FeeTaken(buy, gross, platform, team, land);
    }

    // ---------------- fee tills ----------------

    /// @dev Platform and team shares stay inside the PoolManager as ETH claims owned by this hook, so a swap never
    ///      depends on a recipient accepting ETH. Anyone can trigger the payout; it goes only to the fixed recipient.
    function _credit(address recipient, uint256 amount) private {
        poolManager.mint(address(this), ETH_ID, amount);
        owed[recipient] += amount;
    }

    /// @notice Pay out everything accrued for `recipient` (the platform or the team) as ETH.
    function collect(address recipient) external {
        if (recipient != platformRecipient && recipient != teamRecipient) revert UnknownRecipient();
        uint256 amount = owed[recipient];
        if (amount == 0) revert NothingToCollect();
        owed[recipient] = 0;
        poolManager.unlock(abi.encode(recipient, amount));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address recipient, uint256 amount) = abi.decode(data, (address, uint256));
        poolManager.burn(address(this), ETH_ID, amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, recipient, amount);
        emit Collected(recipient, amount);
        return "";
    }

    // ================= the turn: dice, movement, START, jail =================

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

    /// @dev Passing START pays treasury x min(holder share of circulating MONO, 1%).
    function _payTreasury(address who) private {
        uint256 k = treasury;
        uint256 c = circulating();
        if (k == 0 || c == 0) return;
        uint256 shareBps = IMonoToken(token).balanceOf(who) * BPS / c;
        if (shareBps > TREASURY_CAP_BPS) shareBps = TREASURY_CAP_BPS;
        uint256 payout = k * shareBps / BPS;
        if (payout == 0) return;
        treasury = k - payout;
        _send(who, payout);
        emit Treasury(who, payout);
    }

    // ================= the street market =================

    /// @notice Claim an empty street your piece stands on: base x 1.1 MONO, the base locked as its price.
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

    // ================= reward weight =================

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

    // ================= claims =================

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

    // ================= token helpers =================

    function _pull(address from, uint256 amount) private {
        if (!IMonoToken(token).transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _send(address to, uint256 amount) private {
        if (!IMonoToken(token).transfer(to, amount)) revert TransferFailed();
    }

    /// @notice MONO held by players: supply minus the pool, this contract and the burn address.
    function circulating() public view returns (uint256) {
        IMonoToken t = IMonoToken(token);
        return t.totalSupply() - t.balanceOf(address(poolManager)) - t.balanceOf(address(this)) - t.balanceOf(DEAD);
    }

    // ================= board layout =================

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

    // ================= views =================

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
        shareBps = IMonoToken(token).balanceOf(who) * BPS / c;
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

    // ================= unused callbacks =================

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
