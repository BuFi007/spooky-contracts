// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.24;

import {
    ICctpXFeeManager,
    ICrossChainTokenService,
    ITokenMessengerV2,
    TreasuryBridgeConduit
} from "../src/bufi/conduit/TreasuryBridgeConduit.sol";
import {TreasuryBridgeConduitPermit2} from "../src/bufi/conduit/TreasuryBridgeConduitPermit2.sol";
import {TreasuryConduit} from "../src/bufi/conduit/TreasuryConduit.sol";
import {TreasuryRedeemConduit} from "../src/bufi/conduit/TreasuryRedeemConduit.sol";
import {
    IAaveV3Pool,
    IERC4626Deposit,
    TreasurySwapAndDeposit
} from "../src/bufi/conduit/TreasurySwapAndDeposit.sol";
import {IPermit2SignatureTransfer} from "../src/bufi/conduit/interfaces/IPermit2SignatureTransfer.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Test} from "forge-std/Test.sol";

contract V3TestToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    uint256 public feeBps;
    bool public skipDebitOnAuth;
    bool public skipDebitOnTransferFrom;
    uint256 public shrinkRecipientBy;
    uint256 public transferShave;
    bool public ignoreZeroApprove;
    bool public badApproveValue;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setTransferShave(uint256 shave_) external {
        transferShave = shave_;
    }

    function setConfig(
        uint256 feeBps_,
        bool skipDebitOnAuth_,
        bool skipDebitOnTransferFrom_,
        uint256 shrinkRecipientBy_
    ) external {
        feeBps = feeBps_;
        skipDebitOnAuth = skipDebitOnAuth_;
        skipDebitOnTransferFrom = skipDebitOnTransferFrom_;
        shrinkRecipientBy = shrinkRecipientBy_;
    }

    function setBadAllowance(bool ignoreZero_, bool badValue_) external {
        ignoreZeroApprove = ignoreZero_;
        badApproveValue = badValue_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (ignoreZeroApprove && amount == 0) {
            allowance[msg.sender][spender] = 1;
            return true;
        }
        allowance[msg.sender][spender] = badApproveValue && amount > 0 ? amount - 1 : amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        if (shrinkRecipientBy > 0) {
            balanceOf[to] -= shrinkRecipientBy;
            return true;
        }
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[to] += (amount - fee - transferShave);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        if (!skipDebitOnTransferFrom) {
            balanceOf[from] -= amount;
        }
        uint256 fee = (amount * feeBps) / 10_000;
        balanceOf[to] += (amount - fee);
        return true;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32 nonce,
        bytes calldata
    ) external {
        require(to == msg.sender, "payee");
        require(!authorizationState[from][nonce], "used");
        authorizationState[from][nonce] = true;
        if (!skipDebitOnAuth) {
            balanceOf[from] -= value;
        }
        uint256 fee = (value * feeBps) / 10_000;
        balanceOf[to] += (value - fee);
    }

    function forceTake(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

interface VmDeal {
    function deal(address, uint256) external;
}

/// @notice Accurate 6-decimal native-backed USDC mock mirroring Arc's precompile (`0x3600...0000`).
contract V3MockArcNativeUsdc {
    VmDeal internal constant vmDeal = VmDeal(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint8 public constant decimals = 6;
    address public trackedConduit;
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    function setTrackedConduit(address conduit) external {
        trackedConduit = conduit;
    }

    function mint(address to, uint256 amount) external {
        if (to == trackedConduit) {
            vmDeal.deal(to, to.balance + amount * 1e12);
        } else {
            _balances[to] += amount;
        }
    }

    function balanceOf(address account) public view returns (uint256) {
        if (account == trackedConduit) {
            return account.balance / 1e12;
        }
        return _balances[account];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32 nonce,
        bytes calldata
    ) external {
        require(to == msg.sender, "payee");
        require(!authorizationState[from][nonce], "used");
        authorizationState[from][nonce] = true;
        _move(from, to, value);
    }

    function forceMove(address from, address to, uint256 amount) external {
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal {
        if (from == trackedConduit) {
            uint256 weiDelta = amount * 1e12;
            require(from.balance >= weiDelta, "low native");
            vmDeal.deal(from, from.balance - weiDelta);
        } else {
            _balances[from] -= amount;
        }
        if (to == trackedConduit) {
            vmDeal.deal(to, to.balance + amount * 1e12);
        } else {
            _balances[to] += amount;
        }
    }
}

contract V3MockVenue {
    function swap(address tokenIn, uint256 spendIn, address tokenOut, uint256 deliverOut, address receiver) external {
        if (spendIn > 0) IERC20(tokenIn).transferFrom(msg.sender, address(this), spendIn);
        if (deliverOut > 0) V3TestToken(tokenOut).mint(receiver, deliverOut);
    }

    function swapSameToken(address token, uint256 spendIn, uint256 mintBack) external {
        if (spendIn > 0) IERC20(token).transferFrom(msg.sender, address(this), spendIn);
        if (mintBack > 0) V3TestToken(token).mint(msg.sender, mintBack);
    }

    function consumePrior(address token, uint256 extraTake) external {
        V3TestToken(token).forceTake(msg.sender, address(this), extraTake);
    }

    function deliverDirectInflowOnly(address tokenOut, address recipient, uint256 amount) external {
        V3TestToken(tokenOut).mint(recipient, amount);
    }

    function deliverDirectSharesOnly(V3MockShareVault4626 vault, address recipient, uint256 amount) external {
        vault.mintShares(recipient, amount);
    }

    function alwaysRevert() external pure {
        revert("V3_VENUE_FAIL");
    }

    function reenterSwapAndDeposit(TreasurySwapAndDeposit adapter, address tokenIn, address dest) external {
        adapter.run(tokenIn, 1, address(0), "", TreasurySwapAndDeposit.DestKind.Vault4626, dest, msg.sender, 1);
    }
}

contract V3MockPermit2 is IPermit2SignatureTransfer {
    uint256 public shortDeliverBy;
    bool public skipOwnerDebit;

    function setFaults(uint256 shortDeliverBy_, bool skipOwnerDebit_) external {
        shortDeliverBy = shortDeliverBy_;
        skipOwnerDebit = skipOwnerDebit_;
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return keccak256("V3_MOCK_PERMIT2");
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32,
        string calldata,
        bytes calldata
    ) external {
        uint256 amt = transferDetails.requestedAmount;
        if (permit.permitted.token == 0x3600000000000000000000000000000000000000) {
            V3MockArcNativeUsdc(permit.permitted.token).forceMove(owner, transferDetails.to, amt - shortDeliverBy);
            return;
        }
        if (!skipOwnerDebit) {
            V3TestToken(permit.permitted.token).forceTake(owner, address(this), amt);
        }
        uint256 deliver = amt - shortDeliverBy;
        if (deliver > 0) {
            V3TestToken(permit.permitted.token).mint(transferDetails.to, deliver);
        }
    }
}

contract V3MockTokenMessengerV2 is ITokenMessengerV2 {
    uint256 public lastAmount;
    int256 public burnAdjust;
    address public stealToken;
    uint256 public stealAmount;

    function setFaults(int256 burnAdjust_, address stealToken_, uint256 stealAmount_) external {
        burnAdjust = burnAdjust_;
        stealToken = stealToken_;
        stealAmount = stealAmount_;
    }

    function depositForBurn(uint256 amount, uint32, bytes32, address burnToken, bytes32, uint256, uint32) external {
        lastAmount = amount;
        if (burnAdjust > 0) {
            V3TestToken(burnToken).mint(msg.sender, uint256(burnAdjust));
        } else {
            uint256 pullAmt = burnAdjust < 0 ? amount - uint256(-burnAdjust) : amount;
            if (pullAmt > 0) IERC20(burnToken).transferFrom(msg.sender, address(0xdead), pullAmt);
        }
        if (stealToken != address(0) && stealAmount > 0) {
            V3TestToken(stealToken).forceTake(msg.sender, address(this), stealAmount);
        }
    }
}

contract V3MockFeeManager is ICctpXFeeManager {
    function decodeQuote(bytes calldata signedQuote) external pure returns (Quote memory) {
        require(signedQuote.length >= 2 && signedQuote[0] == 0x01, "bad quote");
        return abi.decode(signedQuote[1:], (Quote));
    }
}

contract V3MockTokenManager {
    function pullBurn(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(0xdead), amount);
    }
}

contract V3ForceEthFeeder {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract V3MockCcts is ICrossChainTokenService {
    VmDeal internal constant vmDeal = VmDeal(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public override feeService;
    mapping(bytes32 => address) public managers;
    mapping(bytes32 => address) public tokenForId;
    int256 public burnAdjust;
    bool public leakNativeBackToConduit;
    address public extraMutateToken;
    int256 public extraMutateDelta;
    uint256 public lastBurnAmount;
    uint256 public lastMsgValue;

    constructor(address feeService_) {
        feeService = feeService_;
    }

    function setFeeService(address feeService_) external {
        feeService = feeService_;
    }

    function setManager(bytes32 tokenId, address manager, address token) external {
        managers[tokenId] = manager;
        tokenForId[tokenId] = token;
    }

    function setFaults(int256 burnAdjust_, bool leakNativeBack_, address extraMutateToken_, int256 extraMutateDelta_)
        external
    {
        burnAdjust = burnAdjust_;
        leakNativeBackToConduit = leakNativeBack_;
        extraMutateToken = extraMutateToken_;
        extraMutateDelta = extraMutateDelta_;
    }

    function resolveTokenManager(bytes32 tokenId) external view returns (address) {
        return managers[tokenId];
    }

    function crossChainTransfer(
        bytes32 tokenId,
        uint256 amount,
        uint32,
        bytes calldata,
        bytes32,
        uint32,
        QuoteClaim calldata,
        bool,
        bytes calldata
    ) external payable {
        lastBurnAmount = amount;
        lastMsgValue = msg.value;
        address token = tokenForId[tokenId];
        address mgr = managers[tokenId];
        if (burnAdjust > 0) {
            V3TestToken(token).mint(msg.sender, uint256(burnAdjust));
        } else {
            uint256 pullAmt = burnAdjust < 0 ? amount - uint256(-burnAdjust) : amount;
            if (pullAmt > 0) V3MockTokenManager(mgr).pullBurn(token, msg.sender, pullAmt);
        }
        if (leakNativeBackToConduit) {
            new V3ForceEthFeeder{value: 1}(payable(msg.sender));
        }
        if (extraMutateToken != address(0) && extraMutateDelta != 0) {
            if (extraMutateDelta < 0) {
                V3TestToken(extraMutateToken).forceTake(msg.sender, address(this), uint256(-extraMutateDelta));
            } else {
                V3TestToken(extraMutateToken).mint(msg.sender, uint256(extraMutateDelta));
            }
        }
    }
}

contract V3MockVault4626 is IERC4626Deposit {
    V3TestToken public immutable assetToken;
    uint256 public pullLimit;
    uint256 public returnShares;
    uint256 public lastDeposited;
    address public lastReceiver;
    uint256 public redeemDeliverAssets;
    uint256 public redeemReturnValue;
    bool public tryReenterRedeem;
    TreasuryRedeemConduit public redeemTarget;

    constructor(V3TestToken assetToken_) {
        assetToken = assetToken_;
    }

    function setDepositConfig(uint256 pullLimit_, uint256 returnShares_) external {
        pullLimit = pullLimit_;
        returnShares = returnShares_;
    }

    function setRedeemConfig(uint256 deliver_, uint256 retVal_, bool reenter_, TreasuryRedeemConduit target_) external {
        redeemDeliverAssets = deliver_;
        redeemReturnValue = retVal_;
        tryReenterRedeem = reenter_;
        redeemTarget = target_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 take = pullLimit > 0 && pullLimit < assets ? pullLimit : assets;
        assetToken.transferFrom(msg.sender, address(this), take);
        lastDeposited = take;
        lastReceiver = receiver;
        return returnShares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        if (tryReenterRedeem) {
            tryReenterRedeem = false;
            redeemTarget.redeem(owner, address(this), shares, 1, block.timestamp + 100, 999, hex"01");
        }
        if (redeemDeliverAssets > 0) assetToken.mint(receiver, redeemDeliverAssets);
        return redeemReturnValue;
    }
}

contract V3MockShareVault4626 is IERC4626Deposit, IERC20 {
    V3TestToken public immutable assetToken;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(V3TestToken assetToken_) {
        assetToken = assetToken_;
    }

    function mintShares(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        assetToken.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract V3MockAavePool is IAaveV3Pool {
    uint256 public lastAmount;
    address public lastOnBehalfOf;
    uint256 public pullLimit;

    function setPullLimit(uint256 limit) external {
        pullLimit = limit;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        uint256 take = pullLimit > 0 && pullLimit < amount ? pullLimit : amount;
        IERC20(asset).transferFrom(msg.sender, address(this), take);
        lastAmount = take;
        lastOnBehalfOf = onBehalfOf;
    }
}

contract V3MockTreasury1271 is IERC1271 {
    bool public accept = true;
    bytes32 public expectedDigest;
    bytes32 public secondDigest;
    bool public checkDigest;

    function setConfig(bool accept_, bool checkDigest_, bytes32 expectedDigest_) external {
        accept = accept_;
        checkDigest = checkDigest_;
        expectedDigest = expectedDigest_;
        secondDigest = bytes32(0);
    }

    function setSecondDigest(bytes32 secondDigest_) external {
        secondDigest = secondDigest_;
    }

    function isValidSignature(bytes32 hash, bytes memory) external view returns (bytes4) {
        if (!accept) return 0xffffffff;
        if (checkDigest && hash != expectedDigest && (secondDigest == bytes32(0) || hash != secondDigest)) {
            return 0xffffffff;
        }
        return IERC1271.isValidSignature.selector;
    }
}

contract TreasuryConduitsV3Test is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant STRANGER = address(0xBAD);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ARC_NATIVE_USDC = 0x3600000000000000000000000000000000000000;
    bytes32 internal constant EURC_ID = keccak256("EURC");

    event TokenSet(address indexed token, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event VenueSet(address indexed venue, bool allowed);
    event DestSet(address indexed dest, bool allowed);
    event Permit2RouteSet(address indexed target, address indexed allowanceTarget, bool allowed);
    event Bridged(
        address indexed treasury,
        bytes32 indexed memoId,
        uint32 indexed destinationDomain,
        bytes32 nonce,
        TreasuryBridgeConduit.BridgeKind kind,
        address bridge,
        address tokenIn,
        uint256 amountIn,
        address bridgeAsset,
        uint256 burnAmount,
        bytes32 mintRecipient,
        uint256 maxFee,
        bytes memo
    );
    event Permit2BridgeSubmitted(
        address indexed treasury,
        bytes32 indexed operationId,
        bytes32 indexed documentCommitment,
        bytes32 intentHash,
        uint256 nonce,
        uint256 burnAmount
    );
    event Redeemed(address indexed treasury, address indexed vault, uint256 shares, uint256 assets, uint256 nonce);

    function _encodeQuote(ICctpXFeeManager.Quote memory quote) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(0x01), abi.encode(quote));
    }

    function _validCctpxQuote(uint256 forwardFee, uint256 protocolFee, uint256 expiry)
        internal
        pure
        returns (bytes memory)
    {
        ICctpXFeeManager.QuoteItem[] memory items = new ICctpXFeeManager.QuoteItem[](2);
        items[0] = ICctpXFeeManager.QuoteItem("FORWARD", bytes32(0), forwardFee);
        items[1] = ICctpXFeeManager.QuoteItem("PROTOCOL", bytes32(0), protocolFee);
        return _encodeQuote(ICctpXFeeManager.Quote(items, expiry, address(0), 1, hex"1234"));
    }

    function _mkConduitIntent(
        address target,
        bytes memory data,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        address beneficiary,
        uint256 deadline
    ) internal pure returns (TreasuryConduit.Intent memory) {
        return TreasuryConduit.Intent({
            target: target,
            data: data,
            tokenIn: tokenIn,
            amountIn: amountIn,
            tokenOut: tokenOut,
            minOut: minOut,
            beneficiary: beneficiary,
            deadline: deadline,
            memoId: keccak256("m"),
            memo: "m"
        });
    }

    function _mkConduitAuth(TreasuryConduit c, TreasuryConduit.Intent memory intent)
        internal
        pure
        returns (TreasuryConduit.Authorization memory)
    {
        return TreasuryConduit.Authorization({
            token: intent.tokenIn,
            from: intent.beneficiary,
            value: intent.amountIn,
            validAfter: 0,
            validBefore: intent.deadline,
            nonce: c.intentNonce(intent)
        });
    }

    function _mkV3BridgeIntent(
        address venue,
        bytes memory venueData,
        address tokenIn,
        uint256 amountIn,
        address bridgeAsset,
        uint256 minBridgeAmount,
        TreasuryBridgeConduit.BridgeKind kind,
        address bridge,
        bytes32 bridgeTokenId,
        uint256 maxFee,
        uint32 minFinality,
        address beneficiary,
        uint256 deadline
    ) internal pure returns (TreasuryBridgeConduit.Intent memory) {
        return TreasuryBridgeConduit.Intent({
            venue: venue,
            venueData: venueData,
            tokenIn: tokenIn,
            amountIn: amountIn,
            bridgeAsset: bridgeAsset,
            minBridgeAmount: minBridgeAmount,
            bridgeKind: kind,
            bridge: bridge,
            bridgeTokenId: bridgeTokenId,
            destinationDomain: 1,
            mintRecipient: bytes32(uint256(uint160(address(0xBEEF)))),
            destinationCaller: bytes32(0),
            maxFee: maxFee,
            minFinalityThreshold: minFinality,
            beneficiary: beneficiary,
            deadline: deadline,
            memoId: keccak256("v3-memo"),
            memo: "v3"
        });
    }

    function _mkV3BridgeAuth(TreasuryBridgeConduit b, TreasuryBridgeConduit.Intent memory intent)
        internal
        pure
        returns (TreasuryBridgeConduit.Authorization memory)
    {
        return TreasuryBridgeConduit.Authorization({
            token: intent.tokenIn,
            from: intent.beneficiary,
            value: intent.amountIn,
            validAfter: 0,
            validBefore: intent.deadline,
            nonce: b.intentNonce(intent)
        });
    }

    function _mkP2Permit(address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (IPermit2SignatureTransfer.PermitTransferFrom memory)
    {
        return IPermit2SignatureTransfer.PermitTransferFrom({
            permitted: IPermit2SignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. v3/TreasuryConduit — BugPoCer 5.1.9, 5.1.13, 5.2.1 + mutations
    // ─────────────────────────────────────────────────────────────────────────

    function test_BugPoCer_5_1_9_5_1_13_5_2_1_v3TreasuryConduit() public {
        vm.warp(1_000);
        TreasuryConduit c = new TreasuryConduit(OWNER);
        V3TestToken tokenIn = new V3TestToken(6);
        V3TestToken tokenOut = new V3TestToken(6);
        V3MockVenue venue = new V3MockVenue();

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        c.setToken(address(0), true);
        c.setTarget(address(venue), true);
        c.setTarget(address(tokenIn), true);
        c.setTarget(address(tokenOut), true);
        c.setTarget(address(c), true);
        vm.stopPrank();

        tokenIn.mint(address(c), 500);
        tokenOut.mint(address(c), 700);
        tokenIn.mint(TREASURY, 1_000);

        bytes memory swapData = abi.encodeCall(V3MockVenue.swap, (address(tokenIn), 70, address(tokenOut), 90, address(c)));
        TreasuryConduit.Intent memory intent =
            _mkConduitIntent(address(venue), swapData, address(tokenIn), 100, address(tokenOut), 90, TREASURY, 1_000);
        TreasuryConduit.Authorization memory auth = _mkConduitAuth(c, intent);

        // 5.2.1: unregistered token reverts
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.TokenNotRegistered.selector, address(tokenIn)));
        c.execute(auth, hex"01", intent);

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true, address(c));
        emit TokenSet(address(tokenIn), true);
        c.setToken(address(tokenIn), true);

        // 5.2.1: inexact pull reverts
        tokenIn.setConfig(100, false, false, 0);
        vm.expectRevert(TreasuryConduit.InexactPull.selector);
        c.execute(auth, hex"01", intent);
        tokenIn.setConfig(0, true, false, 0);
        vm.expectRevert(TreasuryConduit.InexactPull.selector);
        c.execute(auth, hex"01", intent);
        tokenIn.setConfig(0, false, false, 0);

        // 5.1.13: third-party direct inflow to treasury reverts BelowFloor(0, 90)
        TreasuryConduit.Intent memory inflow = _mkConduitIntent(
            address(venue),
            abi.encodeCall(V3MockVenue.deliverDirectInflowOnly, (address(tokenOut), TREASURY, 1_000)),
            address(tokenIn),
            100,
            address(tokenOut),
            90,
            TREASURY,
            1_000
        );
        TreasuryConduit.Authorization memory inflowAuth = _mkConduitAuth(c, inflow);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(90)));
        c.execute(inflowAuth, hex"01", inflow);

        // Forbidden targets + invalid treasury + zero amount
        TreasuryConduit.Intent memory t1 =
            _mkConduitIntent(address(tokenIn), swapData, address(tokenIn), 100, address(tokenOut), 90, TREASURY, 1_000);
        TreasuryConduit.Authorization memory a1 = _mkConduitAuth(c, t1);
        vm.expectRevert(TreasuryConduit.InvalidTarget.selector);
        c.execute(a1, hex"01", t1);

        TreasuryConduit.Intent memory t2 =
            _mkConduitIntent(address(tokenOut), swapData, address(tokenIn), 100, address(tokenOut), 90, TREASURY, 1_000);
        TreasuryConduit.Authorization memory a2 = _mkConduitAuth(c, t2);
        vm.expectRevert(TreasuryConduit.InvalidTarget.selector);
        c.execute(a2, hex"01", t2);

        TreasuryConduit.Intent memory t3 =
            _mkConduitIntent(address(c), swapData, address(tokenIn), 100, address(tokenOut), 90, TREASURY, 1_000);
        TreasuryConduit.Authorization memory a3 = _mkConduitAuth(c, t3);
        vm.expectRevert(TreasuryConduit.InvalidTarget.selector);
        c.execute(a3, hex"01", t3);

        TreasuryConduit.Authorization memory selfAuth = TreasuryConduit.Authorization({
            token: address(tokenIn), from: address(c), value: 100, validAfter: 0, validBefore: 1_000, nonce: auth.nonce
        });
        vm.expectRevert(TreasuryConduit.InvalidTreasury.selector);
        c.execute(selfAuth, hex"01", intent);

        TreasuryConduit.Intent memory zeroAmt =
            _mkConduitIntent(address(venue), swapData, address(tokenIn), 0, address(tokenOut), 0, TREASURY, 1_000);
        TreasuryConduit.Authorization memory zeroA = _mkConduitAuth(c, zeroAmt);
        vm.expectRevert(TreasuryConduit.ZeroAmount.selector);
        c.execute(zeroA, hex"01", zeroAmt);

        // 5.1.9: delta-only sweep preserves stray balances
        c.execute(auth, hex"01", intent);
        assertEq(tokenIn.balanceOf(address(c)), 500, "stray tokenIn preserved");
        assertEq(tokenOut.balanceOf(address(c)), 700, "stray tokenOut preserved");
        assertEq(tokenIn.balanceOf(TREASURY), 930, "unspent 30 refunded");
        assertEq(tokenOut.balanceOf(TREASURY), 90, "90 proceeds delivered");

        // Same-token profit & loss
        TreasuryConduit.Intent memory sameProfit = _mkConduitIntent(
            address(venue),
            abi.encodeCall(V3MockVenue.swapSameToken, (address(tokenIn), 100, 120)),
            address(tokenIn),
            100,
            address(tokenIn),
            20,
            TREASURY,
            1_000
        );
        c.execute(_mkConduitAuth(c, sameProfit), hex"01", sameProfit);
        assertEq(tokenIn.balanceOf(address(c)), 500, "same-token stray preserved");
        assertEq(tokenIn.balanceOf(TREASURY), 950, "same-token profit delivered");

        TreasuryConduit.Intent memory sameLoss = _mkConduitIntent(
            address(venue),
            abi.encodeCall(V3MockVenue.swapSameToken, (address(tokenIn), 100, 50)),
            address(tokenIn),
            100,
            address(tokenIn),
            1,
            TREASURY,
            1_000
        );
        TreasuryConduit.Authorization memory slAuth = _mkConduitAuth(c, sameLoss);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(1)));
        c.execute(slAuth, hex"01", sameLoss);

        TreasuryConduit.Intent memory sameDelta = _mkConduitIntent(
            address(venue),
            abi.encodeCall(V3MockVenue.swapSameToken, (address(tokenIn), 100, 120)),
            address(tokenIn),
            100,
            address(tokenIn),
            20,
            TREASURY,
            1_001
        );
        TreasuryConduit.Authorization memory sdAuth = _mkConduitAuth(c, sameDelta);
        tokenIn.setTransferShave(5);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(15), uint256(20)));
        c.execute(sdAuth, hex"01", sameDelta);
        tokenIn.setTransferShave(0);

        tokenIn.setConfig(0, false, false, 10);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(20)));
        c.execute(sdAuth, hex"01", sameDelta);
        tokenIn.setConfig(0, false, false, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. v3/TreasuryBridgeConduit — BugPoCer 5.1.18, 5.2.1, 5.2.16, 5.2.18, 5.2.19
    // ─────────────────────────────────────────────────────────────────────────

    function test_BugPoCer_5_1_18_5_2_1_5_2_18_v3BridgeConduit() public {
        vm.warp(1_000);
        vm.roll(200);
        TreasuryBridgeConduit b = new TreasuryBridgeConduit(OWNER);
        V3TestToken tokenIn = new V3TestToken(6);
        V3TestToken eurc = new V3TestToken(6);
        V3MockVenue venue = new V3MockVenue();
        V3MockTokenMessengerV2 messenger = new V3MockTokenMessengerV2();
        V3MockFeeManager fm = new V3MockFeeManager();
        V3MockCcts ccts = new V3MockCcts(address(fm));
        V3MockTokenManager mgr = new V3MockTokenManager();
        ccts.setManager(EURC_ID, address(mgr), address(eurc));

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryBridgeConduit.ZeroAddress.selector);
        b.setToken(address(0), true);
        vm.expectRevert(TreasuryBridgeConduit.ZeroAddress.selector);
        b.setTarget(address(0), true);
        vm.expectRevert(TreasuryBridgeConduit.ZeroAddress.selector);
        b.setBridge(TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(0), true);
        vm.expectRevert(TreasuryBridgeConduit.NativeAssetNotAllowed.selector);
        b.setCctpxToken(EURC_ID, ARC_NATIVE_USDC);

        b.setTarget(address(venue), true);
        b.setTarget(address(tokenIn), true);
        b.setTarget(address(eurc), true);
        b.setTarget(address(b), true);
        b.setTarget(address(messenger), true);
        b.setBridge(TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), true);
        b.setBridge(TreasuryBridgeConduit.BridgeKind.CCTPX, address(ccts), true);
        b.setCctpxToken(EURC_ID, address(eurc));
        vm.stopPrank();

        tokenIn.mint(address(b), 300);
        eurc.mint(address(b), 400);
        tokenIn.mint(TREASURY, 1_000);

        bytes memory swapData = abi.encodeCall(V3MockVenue.swap, (address(tokenIn), 70, address(eurc), 60, address(b)));
        TreasuryBridgeConduit.Intent memory intent = _mkV3BridgeIntent(
            address(venue),
            swapData,
            address(tokenIn),
            100,
            address(eurc),
            60,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            1e16,
            2000,
            TREASURY,
            1_000
        );
        TreasuryBridgeConduit.Authorization memory auth = _mkV3BridgeAuth(b, intent);
        bytes memory q1000 = _validCctpxQuote(5e14, 5e14, 1_000);

        // 5.2.1: unregistered ERC-3009 token reverts
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduit.TokenNotRegistered.selector, address(tokenIn)));
        b.execute{value: 1e15}(auth, hex"01", intent, q1000);

        vm.prank(OWNER);
        b.setToken(address(tokenIn), true);

        // 5.2.18: non-zero feeToken, duplicates, PRE_FINALITY, expired block/timestamp rejected
        ICctpXFeeManager.QuoteItem[] memory badItems = new ICctpXFeeManager.QuoteItem[](2);
        badItems[0] = ICctpXFeeManager.QuoteItem("FORWARD", bytes32(0), 5e14);
        badItems[1] = ICctpXFeeManager.QuoteItem("PROTOCOL", bytes32(0), 5e14);
        bytes memory erc20FeeQuote = _encodeQuote(ICctpXFeeManager.Quote(badItems, 1_000, address(eurc), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduit.InvalidBridgeQuote.selector);
        b.execute{value: 1e15}(auth, hex"01", intent, erc20FeeQuote);

        badItems[1] = ICctpXFeeManager.QuoteItem("PRE_FINALITY", bytes32(0), 5e14);
        bytes memory preFinalityOnSlow = _encodeQuote(ICctpXFeeManager.Quote(badItems, 1_000, address(0), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduit.InvalidBridgeQuote.selector);
        b.execute{value: 1e15}(auth, hex"01", intent, preFinalityOnSlow);

        bytes memory expiredBlockQ = _validCctpxQuote(5e14, 5e14, (uint256(1) << 248) | 199);
        vm.expectRevert(TreasuryBridgeConduit.InvalidBridgeQuote.selector);
        b.execute{value: 1e15}(auth, hex"01", intent, expiredBlockQ);

        // 5.1.18: happy path preserves stray 300 tokenIn and 400 eurc, refunds 30 unspent tokenIn
        vm.expectEmit(true, true, true, true, address(b));
        emit Bridged(
            TREASURY,
            intent.memoId,
            1,
            auth.nonce,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            address(tokenIn),
            100,
            address(eurc),
            60,
            intent.mintRecipient,
            1e16,
            "v3"
        );
        b.execute{value: 1e15}(auth, hex"01", intent, q1000);
        assertEq(tokenIn.balanceOf(address(b)), 300, "stray tokenIn preserved");
        assertEq(eurc.balanceOf(address(b)), 400, "stray eurc preserved");
        assertEq(tokenIn.balanceOf(TREASURY), 930, "30 unspent refunded");
        assertEq(ccts.lastBurnAmount(), 60, "burned 60");

        // Post-burn extra drain & extra credit of non-native tokenIn -> PriorBalanceConsumed
        TreasuryBridgeConduit.Intent memory intent2 = _mkV3BridgeIntent(
            address(venue),
            swapData,
            address(tokenIn),
            100,
            address(eurc),
            60,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            1e16,
            2000,
            TREASURY,
            1_500
        );
        TreasuryBridgeConduit.Authorization memory auth2 = _mkV3BridgeAuth(b, intent2);
        bytes memory q1500 = _validCctpxQuote(5e11, 5e11, 1_500);

        ccts.setFaults(0, false, address(tokenIn), -1);
        vm.expectRevert(TreasuryBridgeConduit.PriorBalanceConsumed.selector);
        b.execute{value: 1e12}(auth2, hex"01", intent2, q1500);

        ccts.setFaults(0, false, address(tokenIn), 1);
        vm.expectRevert(TreasuryBridgeConduit.PriorBalanceConsumed.selector);
        b.execute{value: 1e12}(auth2, hex"01", intent2, q1500);
        ccts.setFaults(0, false, address(0), 0);

        // Validation guards: InvalidTarget, VenueIsABridge, ZeroAmount, ZeroBridgeFloor
        TreasuryBridgeConduit.Intent memory badT = _mkV3BridgeIntent(
            address(tokenIn), swapData, address(tokenIn), 100, address(eurc), 60, TreasuryBridgeConduit.BridgeKind.CCTPX, address(ccts), EURC_ID, 1e16, 2000, TREASURY, 1_500
        );
        TreasuryBridgeConduit.Authorization memory badTAuth = _mkV3BridgeAuth(b, badT);
        vm.expectRevert(TreasuryBridgeConduit.InvalidTarget.selector);
        b.execute{value: 1e12}(badTAuth, hex"01", badT, q1500);

        TreasuryBridgeConduit.Intent memory badV = _mkV3BridgeIntent(
            address(messenger), swapData, address(tokenIn), 100, address(eurc), 60, TreasuryBridgeConduit.BridgeKind.CCTPX, address(ccts), EURC_ID, 1e16, 2000, TREASURY, 1_500
        );
        TreasuryBridgeConduit.Authorization memory badVAuth = _mkV3BridgeAuth(b, badV);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduit.VenueIsABridge.selector, address(messenger)));
        b.execute{value: 1e12}(badVAuth, hex"01", badV, q1500);

        TreasuryBridgeConduit.Intent memory zeroI = _mkV3BridgeIntent(
            address(venue), swapData, address(tokenIn), 0, address(eurc), 60, TreasuryBridgeConduit.BridgeKind.CCTPX, address(ccts), EURC_ID, 1e16, 2000, TREASURY, 1_500
        );
        TreasuryBridgeConduit.Authorization memory zeroIAuth = _mkV3BridgeAuth(b, zeroI);
        vm.expectRevert(TreasuryBridgeConduit.ZeroAmount.selector);
        b.execute{value: 1e12}(zeroIAuth, hex"01", zeroI, q1500);

        TreasuryBridgeConduit.Intent memory zeroFloor = _mkV3BridgeIntent(
            address(venue), swapData, address(tokenIn), 100, address(eurc), 0, TreasuryBridgeConduit.BridgeKind.CCTPX, address(ccts), EURC_ID, 1e16, 2000, TREASURY, 1_500
        );
        TreasuryBridgeConduit.Authorization memory zeroFloorAuth = _mkV3BridgeAuth(b, zeroFloor);
        vm.expectRevert(TreasuryBridgeConduit.ZeroBridgeFloor.selector);
        b.execute{value: 1e12}(zeroFloorAuth, hex"01", zeroFloor, q1500);

        // Direct CCTP_V2 bridge with stray balance + BurnMismatch check
        vm.prank(OWNER);
        b.setToken(address(eurc), true);
        eurc.mint(TREASURY, 200);
        TreasuryBridgeConduit.Intent memory directV2 = _mkV3BridgeIntent(
            address(0), "", address(eurc), 100, address(eurc), 100, TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 10, 2000, TREASURY, 1_500
        );
        TreasuryBridgeConduit.Authorization memory directV2Auth = _mkV3BridgeAuth(b, directV2);
        messenger.setFaults(-2, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduit.BurnMismatch.selector, uint256(98), uint256(100)));
        b.execute(directV2Auth, hex"01", directV2, "");

        messenger.setFaults(0, address(0), 0);
        b.execute(directV2Auth, hex"01", directV2, "");
        assertEq(eurc.balanceOf(address(b)), 400, "direct V2 stray preserved");
        assertEq(messenger.lastAmount(), 100, "direct V2 burned 100");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. v3/TreasuryBridgeConduitPermit2 — BugPoCer 5.2.5, 5.1.18, 5.2.16, 5.2.18
    // ─────────────────────────────────────────────────────────────────────────

    function _setupBridgePermit2()
        internal
        returns (
            TreasuryBridgeConduitPermit2 bp2,
            V3MockPermit2 mockP2,
            V3MockArcNativeUsdc arcUsdc,
            V3TestToken eurc,
            V3MockVenue venue,
            V3MockFeeManager fm,
            V3MockCcts ccts,
            V3MockTokenMessengerV2 messenger
        )
    {
        vm.warp(1_000);
        vm.roll(300);
        V3MockPermit2 p2Impl = new V3MockPermit2();
        vm.etch(CANONICAL_PERMIT2, address(p2Impl).code);
        mockP2 = V3MockPermit2(CANONICAL_PERMIT2);

        V3MockArcNativeUsdc arcImpl = new V3MockArcNativeUsdc();
        vm.etch(ARC_NATIVE_USDC, address(arcImpl).code);
        arcUsdc = V3MockArcNativeUsdc(ARC_NATIVE_USDC);

        vm.etch(TREASURY, hex"600080fd");
        eurc = new V3TestToken(6);
        venue = new V3MockVenue();
        fm = new V3MockFeeManager();
        ccts = new V3MockCcts(address(fm));
        V3MockTokenManager mgr = new V3MockTokenManager();
        ccts.setManager(EURC_ID, address(mgr), address(eurc));
        messenger = new V3MockTokenMessengerV2();

        bp2 = new TreasuryBridgeConduitPermit2(OWNER, CANONICAL_PERMIT2);
        arcUsdc.setTrackedConduit(address(bp2));

        vm.startPrank(OWNER);
        bp2.setTarget(address(venue), true);
        bp2.setPermit2Route(address(venue), address(venue), true);
        bp2.setBridge(TreasuryBridgeConduit.BridgeKind.CCTPX, address(ccts), true);
        bp2.setBridge(TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), true);
        bp2.setCctpxToken(EURC_ID, address(eurc));
        vm.stopPrank();
    }

    function test_BugPoCer_5_2_5_v3BridgePermit2ArcNativeUsdcExactAndNonMultipleOf1e12() public {
        (
            TreasuryBridgeConduitPermit2 bp2,
            ,
            V3MockArcNativeUsdc arcUsdc,
            V3TestToken eurc,
            V3MockVenue venue,
            ,
            V3MockCcts ccts,
        ) = _setupBridgePermit2();

        vm.deal(address(bp2), 5 * 1e18 + 6e11);
        eurc.mint(address(bp2), 30);
        arcUsdc.mint(TREASURY, 2_000);

        // Case 1: msg.value = 1.7e12 (NON-MULTIPLE of 1e12!) + dust (6e11) + partial swap refund!
        TreasuryBridgeConduit.Intent memory intent1 = _mkV3BridgeIntent(
            address(venue),
            abi.encodeCall(V3MockVenue.swap, (ARC_NATIVE_USDC, 70, address(eurc), 65, address(bp2))),
            ARC_NATIVE_USDC,
            100,
            address(eurc),
            65,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            5e18,
            2000,
            TREASURY,
            1_000
        );
        IPermit2SignatureTransfer.PermitTransferFrom memory permit1 = _mkP2Permit(ARC_NATIVE_USDC, 100, 11, 1_000);
        bytes32 op1 = keccak256("arc-non-multiple");
        bytes32 doc1 = keccak256("doc-arc-1");
        bytes32 expectedHash1 = bp2.permit2BridgeIntentHash(TREASURY, op1, doc1, address(venue), intent1);
        bytes memory q1 = _validCctpxQuote(10e11, 7e11, 1_000);

        vm.expectEmit(true, true, true, true, address(bp2));
        emit Permit2BridgeSubmitted(TREASURY, op1, doc1, expectedHash1, 11, 65);
        bp2.executePermit2{value: 17e11}(permit1, TREASURY, hex"01", op1, doc1, address(venue), intent1, q1);

        assertEq(address(bp2).balance, 5 * 1e18 + 6e11, "stray native + dust exact after non-multiple 1e12");
        assertEq(eurc.balanceOf(address(bp2)), 30, "stray eurc exact");
        assertEq(arcUsdc.balanceOf(TREASURY), 1_930, "30 unspent refunded cleanly before burn");
        assertEq(ccts.lastBurnAmount(), 65, "65 EURC burned");

        // Case 2: msg.value = 2e18 (EXACT multiple of 1e12) + partial swap refund
        TreasuryBridgeConduit.Intent memory intent2 = _mkV3BridgeIntent(
            address(venue),
            abi.encodeCall(V3MockVenue.swap, (ARC_NATIVE_USDC, 60, address(eurc), 55, address(bp2))),
            ARC_NATIVE_USDC,
            100,
            address(eurc),
            55,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            5e18,
            1000,
            TREASURY,
            2_000
        );
        IPermit2SignatureTransfer.PermitTransferFrom memory permit2 = _mkP2Permit(ARC_NATIVE_USDC, 100, 12, 2_000);
        bytes memory q2 = _validCctpxQuote(1e18, 1e18, 2_000);
        bp2.executePermit2{value: 2e18}(
            permit2, TREASURY, hex"01", keccak256("arc-exact-multiple"), bytes32(0), address(venue), intent2, q2
        );

        assertEq(address(bp2).balance, 5 * 1e18 + 6e11, "stray native + dust exact after exact multiple");
        assertEq(arcUsdc.balanceOf(TREASURY), 1_870, "40 unspent refunded");

        // Case 2b: sub-unit native fee (3e11) where nativeBefore / 1e12 == tokenInBefore (zero drop slack)
        bytes memory qSub = _validCctpxQuote(2e11, 1e11, 2_000);
        bp2.executePermit2{value: 3e11}(
            _mkP2Permit(ARC_NATIVE_USDC, 100, 13, 2_000),
            TREASURY,
            hex"01",
            keccak256("arc-sub-unit"),
            bytes32(0),
            address(venue),
            intent2,
            qSub
        );
        assertEq(address(bp2).balance, 5 * 1e18 + 6e11, "stray native + dust exact after sub-unit fee");

        // Case 3: CCTS leaks 1 wei back to conduit -> NativeBalanceMismatch
        ccts.setFaults(0, true, address(0), 0);
        bytes memory q3 = _validCctpxQuote(5e11, 5e11, 2_000);
        vm.expectRevert(TreasuryBridgeConduit.NativeBalanceMismatch.selector);
        bp2.executePermit2{value: 1e12}(
            permit2, TREASURY, hex"01", keccak256("arc-leak"), bytes32(0), address(venue), intent2, q3
        );
    }

    function test_v3BridgePermit2_allValidationQuoteAndAllowanceChecks() public {
        (
            TreasuryBridgeConduitPermit2 bp2,
            V3MockPermit2 mockP2,
            ,
            V3TestToken eurc,
            V3MockVenue venue,
            ,
            V3MockCcts ccts,
            V3MockTokenMessengerV2 messenger
        ) = _setupBridgePermit2();

        V3TestToken tokenIn = new V3TestToken(6);

        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Deployment.selector);
        new TreasuryBridgeConduitPermit2(OWNER, address(0x1234));

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", STRANGER));
        bp2.setPermit2Route(address(venue), address(venue), true);

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.setPermit2Route(address(0xdead), address(venue), true);
        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.setPermit2Route(address(venue), address(0xdead), true);
        bp2.setPermit2Route(address(0xdead), address(0xdead), false);
        bp2.setTarget(CANONICAL_PERMIT2, true);
        bp2.setPermit2Route(CANONICAL_PERMIT2, address(venue), true);
        vm.stopPrank();

        tokenIn.mint(TREASURY, 2_000);
        tokenIn.mint(address(bp2), 100);
        eurc.mint(address(bp2), 200);

        bytes memory swapData = abi.encodeCall(V3MockVenue.swap, (address(tokenIn), 80, address(eurc), 75, address(bp2)));
        TreasuryBridgeConduit.Intent memory intent = _mkV3BridgeIntent(
            address(venue), swapData, address(tokenIn), 100, address(eurc), 75, TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        IPermit2SignatureTransfer.PermitTransferFrom memory permit = _mkP2Permit(address(tokenIn), 100, 1, 2_000);
        bytes32 opId = keccak256("bp2-op-1");

        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.executePermit2(permit, address(bp2), hex"01", opId, bytes32(0), address(venue), intent, "");
        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.executePermit2(permit, STRANGER, hex"01", opId, bytes32(0), address(venue), intent, "");
        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", bytes32(0), bytes32(0), address(venue), intent, "");

        TreasuryBridgeConduit.Intent memory zeroIn = _mkV3BridgeIntent(
            address(venue), swapData, address(tokenIn), 0, address(eurc), 75, TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), zeroIn, "");

        TreasuryBridgeConduit.Intent memory zeroMin = _mkV3BridgeIntent(
            address(venue), swapData, address(tokenIn), 100, address(eurc), 0, TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), zeroMin, "");

        vm.expectRevert(TreasuryBridgeConduitPermit2.Permit2DeadlineMismatch.selector);
        bp2.executePermit2(_mkP2Permit(address(tokenIn), 100, 1, 1_999), TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");

        vm.warp(2_001);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryBridgeConduit.IntentExpired.selector, uint256(2_000), uint256(2_001))
        );
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");
        vm.warp(1_000);

        TreasuryBridgeConduit.Intent memory direct = _mkV3BridgeIntent(
            address(0), "", address(eurc), 100, address(eurc), 100, TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        IPermit2SignatureTransfer.PermitTransferFrom memory directPermit = _mkP2Permit(address(eurc), 100, 2, 2_000);
        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.executePermit2(directPermit, TREASURY, hex"01", opId, bytes32(0), address(venue), direct, "");

        TreasuryBridgeConduit.Intent memory p2Venue = _mkV3BridgeIntent(
            CANONICAL_PERMIT2, swapData, address(tokenIn), 100, address(eurc), 75, TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        vm.expectRevert(TreasuryBridgeConduitPermit2.InvalidPermit2Intent.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), p2Venue, "");

        vm.expectRevert(TreasuryBridgeConduitPermit2.Permit2RouteNotRegistered.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(eurc), intent, "");

        // InexactInput on pull
        mockP2.setFaults(1, false);
        vm.expectRevert(TreasuryBridgeConduitPermit2.InexactInput.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");
        mockP2.setFaults(0, true);
        vm.expectRevert(TreasuryBridgeConduitPermit2.InexactInput.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");
        mockP2.setFaults(0, false);

        // AllowanceMismatch on venue approve & bridge approve
        tokenIn.setBadAllowance(false, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduit.AllowanceMismatch.selector,
                address(tokenIn),
                address(venue),
                uint256(100),
                uint256(99)
            )
        );
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");
        tokenIn.setBadAllowance(false, false);

        eurc.setBadAllowance(false, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduit.AllowanceMismatch.selector,
                address(eurc),
                address(messenger),
                uint256(75),
                uint256(74)
            )
        );
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");

        eurc.setBadAllowance(true, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduit.AllowanceMismatch.selector,
                address(eurc),
                address(messenger),
                uint256(0),
                uint256(1)
            )
        );
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");
        eurc.setBadAllowance(false, false);

        // 5.2.18 quote validation enforced on executePermit2 CCTPX path
        TreasuryBridgeConduit.Intent memory cctpxIntent = _mkV3BridgeIntent(
            address(venue),
            abi.encodeCall(V3MockVenue.swap, (address(tokenIn), 100, address(eurc), 75, address(bp2))),
            address(tokenIn),
            100,
            address(eurc),
            75,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            1e15,
            2000,
            TREASURY,
            2_000
        );
        vm.expectRevert(TreasuryBridgeConduit.InvalidBridgeQuote.selector);
        bp2.executePermit2{value: 1e14}(
            permit, TREASURY, hex"01", opId, bytes32(0), address(venue), cctpxIntent, hex"0200"
        );

        // Happy path CCTP_V2 with partial swap + replay blocked
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");
        assertEq(tokenIn.balanceOf(address(bp2)), 100, "stray tokenIn preserved");
        assertEq(eurc.balanceOf(address(bp2)), 200, "stray eurc preserved");
        assertEq(tokenIn.balanceOf(TREASURY), 1_920, "20 unspent refunded");
        assertTrue(bp2.executed(TREASURY, opId), "op marked executed");

        vm.expectRevert(TreasuryBridgeConduitPermit2.OperationAlreadyExecuted.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", opId, bytes32(0), address(venue), intent, "");

        // Direct CCTP_V2 (venue == 0, allowanceTarget == 0) succeeds and keeps stray eurc
        eurc.mint(TREASURY, 150);
        bp2.executePermit2(directPermit, TREASURY, hex"01", keccak256("bp2-direct"), bytes32(0), address(0), direct, "");
        assertEq(eurc.balanceOf(address(bp2)), 200, "direct permit2 stray preserved");
        assertEq(messenger.lastAmount(), 100, "direct permit2 burned 100");

        // Post-burn non-native tokenIn steal when msg.value == 0 -> PriorBalanceConsumed
        messenger.setFaults(0, address(tokenIn), 5);
        vm.expectRevert(TreasuryBridgeConduit.PriorBalanceConsumed.selector);
        bp2.executePermit2(permit, TREASURY, hex"01", keccak256("bp2-steal"), bytes32(0), address(venue), intent, "");
        messenger.setFaults(0, address(0), 0);

        // Post-burn -1 drop on non-Arc ERC-20 tokenIn with msg.value > 0 -> PriorBalanceConsumed
        bytes memory validQ = _validCctpxQuote(5e11, 5e11, 2_000);
        ccts.setFaults(0, false, address(tokenIn), -1);
        vm.expectRevert(TreasuryBridgeConduit.PriorBalanceConsumed.selector);
        bp2.executePermit2{value: 1e12}(
            permit, TREASURY, hex"01", keccak256("bp2-cctpx-steal"), bytes32(0), address(venue), cctpxIntent, validQ
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. v3/TreasurySwapAndDeposit — BugPoCer 5.1.17, 5.2.19 + mutations
    // ─────────────────────────────────────────────────────────────────────────

    function test_BugPoCer_5_1_17_v3SwapAndDepositDeltaOnlyAndAllPaths() public {
        V3TestToken usdc = new V3TestToken(6);
        V3TestToken eurc = new V3TestToken(6);
        V3MockVenue venue = new V3MockVenue();
        V3MockVault4626 vault = new V3MockVault4626(usdc);
        V3MockAavePool aave = new V3MockAavePool();

        vm.expectRevert(TreasurySwapAndDeposit.ZeroAddress.selector);
        new TreasurySwapAndDeposit(OWNER, address(0));

        TreasurySwapAndDeposit sad = new TreasurySwapAndDeposit(OWNER, address(usdc));

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", STRANGER));
        sad.setVenue(address(venue), true);

        vm.startPrank(OWNER);
        vm.expectRevert(TreasurySwapAndDeposit.ZeroAddress.selector);
        sad.setVenue(address(0), true);
        vm.expectRevert(TreasurySwapAndDeposit.ZeroAddress.selector);
        sad.setDest(address(0), true);

        vm.expectEmit(true, false, false, true, address(sad));
        emit VenueSet(address(venue), true);
        sad.setVenue(address(venue), true);
        sad.setVenue(address(eurc), true);
        sad.setVenue(address(usdc), true);
        sad.setVenue(address(sad), true);

        vm.expectEmit(true, false, false, true, address(sad));
        emit DestSet(address(vault), true);
        sad.setDest(address(vault), true);
        sad.setDest(address(aave), true);
        vm.stopPrank();

        usdc.mint(address(sad), 1_000);
        eurc.mint(address(sad), 500);
        usdc.mint(address(this), 2_000);
        eurc.mint(address(this), 2_000);
        usdc.approve(address(sad), type(uint256).max);
        eurc.approve(address(sad), type(uint256).max);

        vault.setDepositConfig(0, 100);
        vm.expectRevert(abi.encodeWithSelector(TreasurySwapAndDeposit.BelowUsdcFloor.selector, uint256(50), uint256(90)));
        sad.run(
            address(eurc),
            100,
            address(venue),
            abi.encodeCall(V3MockVenue.swap, (address(eurc), 100, address(usdc), 50, address(sad))),
            TreasurySwapAndDeposit.DestKind.Vault4626,
            address(vault),
            TREASURY,
            90
        );

        vault.setDepositConfig(100, 100);
        sad.run(
            address(eurc),
            100,
            address(venue),
            abi.encodeCall(V3MockVenue.swap, (address(eurc), 70, address(usdc), 110, address(sad))),
            TreasurySwapAndDeposit.DestKind.Vault4626,
            address(vault),
            TREASURY,
            110
        );
        assertEq(vault.lastDeposited(), 100, "deposited from swap proceeds only");
        assertEq(vault.lastReceiver(), TREASURY, "beneficiary");
        assertEq(eurc.balanceOf(address(sad)), 500, "stray eurc preserved");
        assertEq(usdc.balanceOf(address(sad)), 1_000, "stray usdc preserved");
        assertEq(eurc.balanceOf(address(this)), 1_930, "30 unspent eurc refunded");
        assertEq(usdc.balanceOf(address(this)), 2_010, "10 unconsumed swapped usdc refunded");
        assertEq(eurc.allowance(address(sad), address(venue)), 0, "venue allowance 0");
        assertEq(usdc.allowance(address(sad), address(vault)), 0, "vault allowance 0");

        aave.setPullLimit(80);
        sad.run(
            address(usdc),
            100,
            address(0),
            "",
            TreasurySwapAndDeposit.DestKind.AaveV3Supply,
            address(aave),
            TREASURY,
            100
        );
        assertEq(aave.lastAmount(), 80, "supplied 80");
        assertEq(aave.lastOnBehalfOf(), TREASURY, "onBehalfOf");
        assertEq(usdc.balanceOf(address(sad)), 1_000, "direct path stray usdc preserved");
        assertEq(usdc.balanceOf(address(this)), 1_930, "20 unconsumed direct usdc refunded");
        assertEq(usdc.allowance(address(sad), address(aave)), 0, "aave allowance 0");

        vm.expectRevert(TreasurySwapAndDeposit.ZeroAddress.selector);
        sad.run(address(usdc), 10, address(0), "", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), address(0), 1);

        vm.expectRevert(TreasurySwapAndDeposit.ZeroAddress.selector);
        sad.run(address(0), 10, address(0), "", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(TreasurySwapAndDeposit.ZeroAmount.selector);
        sad.run(address(usdc), 0, address(0), "", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 0);

        vm.expectRevert(abi.encodeWithSelector(TreasurySwapAndDeposit.DestNotRegistered.selector, STRANGER));
        sad.run(address(usdc), 10, address(0), "", TreasurySwapAndDeposit.DestKind.AaveV3Supply, STRANGER, TREASURY, 1);

        eurc.setConfig(500, false, false, 0);
        vm.expectRevert(TreasurySwapAndDeposit.InexactPull.selector);
        sad.run(
            address(eurc),
            100,
            address(venue),
            abi.encodeCall(V3MockVenue.swap, (address(eurc), 100, address(usdc), 100, address(sad))),
            TreasurySwapAndDeposit.DestKind.AaveV3Supply,
            address(aave),
            TREASURY,
            100
        );
        eurc.setConfig(0, false, false, 0);

        vm.expectRevert(abi.encodeWithSelector(TreasurySwapAndDeposit.VenueNotRegistered.selector, address(0)));
        sad.run(address(eurc), 10, address(0), hex"01", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(abi.encodeWithSelector(TreasurySwapAndDeposit.VenueNotRegistered.selector, STRANGER));
        sad.run(address(eurc), 10, STRANGER, hex"01", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(TreasurySwapAndDeposit.InvalidTarget.selector);
        sad.run(address(eurc), 10, address(eurc), hex"01", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(TreasurySwapAndDeposit.InvalidTarget.selector);
        sad.run(address(eurc), 10, address(usdc), hex"01", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(TreasurySwapAndDeposit.InvalidTarget.selector);
        sad.run(address(eurc), 10, address(sad), hex"01", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(TreasurySwapAndDeposit.SwapRequired.selector);
        sad.run(address(eurc), 10, address(venue), "", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TreasurySwapAndDeposit.SwapFailed.selector, abi.encodeWithSignature("Error(string)", "V3_VENUE_FAIL")
            )
        );
        sad.run(
            address(eurc),
            10,
            address(venue),
            abi.encodeCall(V3MockVenue.alwaysRevert, ()),
            TreasurySwapAndDeposit.DestKind.AaveV3Supply,
            address(aave),
            TREASURY,
            1
        );

        vm.expectRevert(TreasurySwapAndDeposit.UnexpectedSwap.selector);
        sad.run(address(usdc), 10, address(venue), "", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(TreasurySwapAndDeposit.UnexpectedSwap.selector);
        sad.run(address(usdc), 10, address(0), hex"01", TreasurySwapAndDeposit.DestKind.AaveV3Supply, address(aave), TREASURY, 1);

        vm.expectRevert(TreasurySwapAndDeposit.PriorBalanceConsumed.selector);
        sad.run(
            address(eurc),
            10,
            address(venue),
            abi.encodeCall(V3MockVenue.consumePrior, (address(usdc), 1)),
            TreasurySwapAndDeposit.DestKind.AaveV3Supply,
            address(aave),
            TREASURY,
            0
        );

        vm.expectRevert(TreasurySwapAndDeposit.PriorBalanceConsumed.selector);
        sad.run(
            address(eurc),
            10,
            address(venue),
            abi.encodeCall(V3MockVenue.consumePrior, (address(eurc), 11)),
            TreasurySwapAndDeposit.DestKind.AaveV3Supply,
            address(aave),
            TREASURY,
            0
        );

        usdc.mint(address(venue), 100);
        vm.prank(address(venue));
        usdc.approve(address(sad), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasurySwapAndDeposit.SwapFailed.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            )
        );
        sad.run(
            address(eurc),
            10,
            address(venue),
            abi.encodeCall(V3MockVenue.reenterSwapAndDeposit, (sad, address(usdc), address(vault))),
            TreasurySwapAndDeposit.DestKind.Vault4626,
            address(vault),
            TREASURY,
            0
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. v3/TreasuryRedeemConduit — full unit & mutation-killing coverage
    // ─────────────────────────────────────────────────────────────────────────

    function test_v3RedeemConduit_fullCoverageAndReturnedAssetsCheck() public {
        vm.warp(1_000);
        TreasuryRedeemConduit rc = new TreasuryRedeemConduit(OWNER);
        V3TestToken asset = new V3TestToken(6);
        V3MockTreasury1271 treasury = new V3MockTreasury1271();
        V3MockVault4626 vault = new V3MockVault4626(asset);

        vm.prank(OWNER);
        rc.setVault(address(vault), true);

        bytes32 h0 = rc.redeemHash(address(treasury), address(vault), 100, 90, 1_000, 1);
        assertTrue(h0 != rc.redeemHash(STRANGER, address(vault), 100, 90, 1_000, 1));
        assertTrue(h0 != rc.redeemHash(address(treasury), STRANGER, 100, 90, 1_000, 1));
        assertTrue(h0 != rc.redeemHash(address(treasury), address(vault), 101, 90, 1_000, 1));
        assertTrue(h0 != rc.redeemHash(address(treasury), address(vault), 100, 91, 1_000, 1));
        assertTrue(h0 != rc.redeemHash(address(treasury), address(vault), 100, 90, 1_001, 1));
        assertTrue(h0 != rc.redeemHash(address(treasury), address(vault), 100, 90, 1_000, 2));

        vm.expectRevert(abi.encodeWithSelector(TreasuryRedeemConduit.VaultNotRegistered.selector, STRANGER));
        rc.redeem(address(treasury), STRANGER, 100, 90, 1_000, 1, hex"01");

        vm.expectRevert(TreasuryRedeemConduit.ZeroShares.selector);
        rc.redeem(address(treasury), address(vault), 0, 90, 1_000, 1, hex"01");

        vm.expectRevert(abi.encodeWithSelector(TreasuryRedeemConduit.RedeemExpired.selector, uint256(999), uint256(1_000)));
        rc.redeem(address(treasury), address(vault), 100, 90, 999, 1, hex"01");

        treasury.setConfig(false, false, bytes32(0));
        vm.expectRevert(TreasuryRedeemConduit.InvalidQuorumSignature.selector);
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");

        treasury.setConfig(true, true, h0);
        vault.setRedeemConfig(89, 100, false, rc);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRedeemConduit.BelowFloor.selector, uint256(89), uint256(90)));
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");

        vault.setRedeemConfig(100, 89, false, rc);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRedeemConduit.BelowFloor.selector, uint256(100), uint256(90)));
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");

        treasury.setSecondDigest(rc.redeemHash(address(treasury), address(vault), 100, 1, block.timestamp + 100, 999));
        vault.setRedeemConfig(90, 90, true, rc);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");
        treasury.setSecondDigest(bytes32(0));

        vault.setRedeemConfig(90, 90, false, rc);
        vm.expectEmit(true, true, false, true, address(rc));
        emit Redeemed(address(treasury), address(vault), 100, 90, 1);
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");
        assertTrue(rc.usedNonces(address(treasury), 1));
        assertEq(asset.balanceOf(address(treasury)), 90);

        vm.expectRevert(abi.encodeWithSelector(TreasuryRedeemConduit.NonceUsed.selector, uint256(1)));
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");
    }

    function test_v3Conduits_fullValidationHashSensitivityAndMutationHardening() public {
        vm.warp(1_000);
        vm.roll(400);

        // 1. v3/TreasuryConduit exhaustive validation & intentNonce sensitivity
        TreasuryConduit tc = new TreasuryConduit(OWNER);
        V3TestToken tokA = new V3TestToken(6);
        V3TestToken tokB = new V3TestToken(6);
        V3MockVenue venue = new V3MockVenue();
        vm.startPrank(OWNER);
        tc.setTarget(address(venue), true);
        tc.setToken(address(tokA), true);
        vm.stopPrank();
        tokA.mint(TREASURY, 1_000);
        tokA.mint(address(tc), 100);
        tokB.mint(address(tc), 100);

        bytes memory swapData = abi.encodeCall(V3MockVenue.swap, (address(tokA), 100, address(tokB), 80, address(tc)));
        TreasuryConduit.Intent memory ti =
            _mkConduitIntent(address(venue), swapData, address(tokA), 100, address(tokB), 80, TREASURY, 1_500);
        TreasuryConduit.Authorization memory ta = _mkConduitAuth(tc, ti);

        assertTrue(ta.nonce != tc.intentNonce(_mkConduitIntent(STRANGER, swapData, address(tokA), 100, address(tokB), 80, TREASURY, 1_500)));
        assertTrue(ta.nonce != tc.intentNonce(_mkConduitIntent(address(venue), hex"ff", address(tokA), 100, address(tokB), 80, TREASURY, 1_500)));
        assertTrue(ta.nonce != tc.intentNonce(_mkConduitIntent(address(venue), swapData, address(tokB), 100, address(tokB), 80, TREASURY, 1_500)));
        assertTrue(ta.nonce != tc.intentNonce(_mkConduitIntent(address(venue), swapData, address(tokA), 101, address(tokB), 80, TREASURY, 1_500)));
        assertTrue(ta.nonce != tc.intentNonce(_mkConduitIntent(address(venue), swapData, address(tokA), 100, address(tokA), 80, TREASURY, 1_500)));
        assertTrue(ta.nonce != tc.intentNonce(_mkConduitIntent(address(venue), swapData, address(tokA), 100, address(tokB), 81, TREASURY, 1_500)));
        assertTrue(ta.nonce != tc.intentNonce(_mkConduitIntent(address(venue), swapData, address(tokA), 100, address(tokB), 80, STRANGER, 1_500)));
        assertTrue(ta.nonce != tc.intentNonce(_mkConduitIntent(address(venue), swapData, address(tokA), 100, address(tokB), 80, TREASURY, 1_501)));

        vm.expectRevert(TreasuryConduit.InvalidTreasury.selector);
        tc.execute(TreasuryConduit.Authorization(address(tokA), address(0), 100, 0, 1_500, ta.nonce), hex"01", ti);

        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BeneficiaryMismatch.selector, TREASURY, STRANGER));
        tc.execute(TreasuryConduit.Authorization(address(tokA), STRANGER, 100, 0, 1_500, ta.nonce), hex"01", ti);

        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.TokenMismatch.selector, address(tokA), address(tokB)));
        tc.execute(TreasuryConduit.Authorization(address(tokB), TREASURY, 100, 0, 1_500, ta.nonce), hex"01", ti);

        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.AmountMismatch.selector, uint256(100), uint256(99)));
        tc.execute(TreasuryConduit.Authorization(address(tokA), TREASURY, 99, 0, 1_500, ta.nonce), hex"01", ti);

        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.NonceIsNotTheIntent.selector, bytes32(uint256(1)), ta.nonce));
        tc.execute(TreasuryConduit.Authorization(address(tokA), TREASURY, 100, 0, 1_500, bytes32(uint256(1))), hex"01", ti);

        vm.warp(1_501);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.IntentExpired.selector, uint256(1_500), uint256(1_501)));
        tc.execute(ta, hex"01", ti);
        vm.warp(1_000);

        TreasuryConduit.Intent memory unreg =
            _mkConduitIntent(STRANGER, swapData, address(tokA), 100, address(tokB), 80, TREASURY, 1_500);
        TreasuryConduit.Authorization memory unregA = _mkConduitAuth(tc, unreg);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.TargetNotRegistered.selector, STRANGER));
        tc.execute(unregA, hex"01", unreg);

        TreasuryConduit.Intent memory zeroOut =
            _mkConduitIntent(address(venue), swapData, address(tokA), 100, address(0), 0, TREASURY, 1_500);
        TreasuryConduit.Authorization memory zeroOutA = _mkConduitAuth(tc, zeroOut);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        tc.execute(zeroOutA, hex"01", zeroOut);

        TreasuryConduit.Intent memory failCall = _mkConduitIntent(
            address(venue), abi.encodeCall(V3MockVenue.alwaysRevert, ()), address(tokA), 100, address(tokB), 0, TREASURY, 1_500
        );
        TreasuryConduit.Authorization memory failCallA = _mkConduitAuth(tc, failCall);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryConduit.TargetCallFailed.selector, abi.encodeWithSignature("Error(string)", "V3_VENUE_FAIL")
            )
        );
        tc.execute(failCallA, hex"01", failCall);

        TreasuryConduit.Intent memory stealIn = _mkConduitIntent(
            address(venue), abi.encodeCall(V3MockVenue.consumePrior, (address(tokA), 101)), address(tokA), 100, address(tokB), 0, TREASURY, 1_500
        );
        TreasuryConduit.Authorization memory stealInA = _mkConduitAuth(tc, stealIn);
        vm.expectRevert(TreasuryConduit.PriorBalanceConsumed.selector);
        tc.execute(stealInA, hex"01", stealIn);

        TreasuryConduit.Intent memory stealOut = _mkConduitIntent(
            address(venue), abi.encodeCall(V3MockVenue.consumePrior, (address(tokB), 1)), address(tokA), 100, address(tokB), 0, TREASURY, 1_500
        );
        TreasuryConduit.Authorization memory stealOutA = _mkConduitAuth(tc, stealOut);
        vm.expectRevert(TreasuryConduit.PriorBalanceConsumed.selector);
        tc.execute(stealOutA, hex"01", stealOut);

        // Fee-on-transfer tokenOut drops gained below minOut, and shrinkRecipient reverts BelowFloor(0, minOut)
        tokB.setConfig(1000, false, false, 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(72), uint256(80)));
        tc.execute(ta, hex"01", ti);

        tokB.mint(TREASURY, 50);
        tokB.setConfig(0, false, false, 10);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(80)));
        tc.execute(ta, hex"01", ti);
        tokB.setConfig(0, false, false, 0);

        // 2. v3/TreasuryBridgeConduit & Permit2 exhaustive checks:
        //    Arc native USDC via ERC-3009 execute, quote edge cases, BridgeTokenMismatch, NonEvmRecipient,
        //    permit2BridgeIntentHash sensitivity, CCTPX AllowanceMismatch on TokenManager, PriorBalanceConsumed
        (
            TreasuryBridgeConduitPermit2 bp2,
            ,
            V3MockArcNativeUsdc arcUsdc,
            V3TestToken eurc,
            V3MockVenue bVenue,
            ,
            V3MockCcts ccts,
            V3MockTokenMessengerV2 messenger
        ) = _setupBridgePermit2();

        vm.prank(OWNER);
        bp2.setToken(ARC_NATIVE_USDC, true);

        vm.deal(address(bp2), 3 * 1e18 + 6e11);
        arcUsdc.mint(TREASURY, 1_000);
        eurc.mint(address(bp2), 100);

        TreasuryBridgeConduit.Intent memory arcExec = _mkV3BridgeIntent(
            address(bVenue),
            abi.encodeCall(V3MockVenue.swap, (ARC_NATIVE_USDC, 80, address(eurc), 70, address(bp2))),
            ARC_NATIVE_USDC,
            100,
            address(eurc),
            70,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            2e18,
            1500,
            TREASURY,
            2_000
        );
        TreasuryBridgeConduit.Authorization memory arcAuth = _mkV3BridgeAuth(bp2, arcExec);

        // permit2BridgeIntentHash sensitivity
        bytes32 h0 = bp2.permit2BridgeIntentHash(TREASURY, keccak256("op"), keccak256("doc"), address(bVenue), arcExec);
        assertTrue(h0 != bp2.permit2BridgeIntentHash(STRANGER, keccak256("op"), keccak256("doc"), address(bVenue), arcExec));
        assertTrue(h0 != bp2.permit2BridgeIntentHash(TREASURY, keccak256("op2"), keccak256("doc"), address(bVenue), arcExec));
        assertTrue(h0 != bp2.permit2BridgeIntentHash(TREASURY, keccak256("op"), keccak256("doc2"), address(bVenue), arcExec));
        assertTrue(h0 != bp2.permit2BridgeIntentHash(TREASURY, keccak256("op"), keccak256("doc"), STRANGER, arcExec));

        // ERC-3009 execute on Arc native USDC with non-multiple 1e12 + PRE_FINALITY + block expiry
        ICctpXFeeManager.QuoteItem[] memory fastItems = new ICctpXFeeManager.QuoteItem[](3);
        fastItems[0] = ICctpXFeeManager.QuoteItem("FORWARD", bytes32(0), 10e11);
        fastItems[1] = ICctpXFeeManager.QuoteItem("PROTOCOL", bytes32(0), 5e11);
        fastItems[2] = ICctpXFeeManager.QuoteItem("PRE_FINALITY", bytes32(0), 2e11);
        bytes memory fastQ = _encodeQuote(
            ICctpXFeeManager.Quote(fastItems, (uint256(1) << 248) | 400, address(0), 9, hex"abcd")
        );
        bp2.execute{value: 17e11}(arcAuth, hex"01", arcExec, fastQ);
        assertEq(address(bp2).balance, 3 * 1e18 + 6e11, "v3 execute Arc native stray + dust preserved");
        assertEq(arcUsdc.balanceOf(TREASURY), 920, "v3 execute refunded 20 unspent");

        // CCTPX AllowanceMismatch on TokenManager via executePermit2
        eurc.setBadAllowance(false, true);
        IPermit2SignatureTransfer.PermitTransferFrom memory pArc = _mkP2Permit(ARC_NATIVE_USDC, 100, 55, 2_000);
        address tm = ccts.resolveTokenManager(EURC_ID);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduit.AllowanceMismatch.selector, address(eurc), tm, uint256(70), uint256(69)
            )
        );
        bp2.executePermit2{value: 17e11}(pArc, TREASURY, hex"01", keccak256("tm-allow"), bytes32(0), address(bVenue), arcExec, fastQ);
        eurc.setBadAllowance(false, false);

        // BurnMismatch, BelowFloor, TargetCallFailed, PriorBalanceConsumed on executePermit2
        ccts.setFaults(-1, false, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduit.BurnMismatch.selector, uint256(69), uint256(70)));
        bp2.executePermit2{value: 17e11}(pArc, TREASURY, hex"01", keccak256("bm"), bytes32(0), address(bVenue), arcExec, fastQ);
        ccts.setFaults(0, false, address(0), 0);

        TreasuryBridgeConduit.Intent memory lowFloor = _mkV3BridgeIntent(
            address(bVenue),
            abi.encodeCall(V3MockVenue.swap, (ARC_NATIVE_USDC, 80, address(eurc), 10, address(bp2))),
            ARC_NATIVE_USDC,
            100,
            address(eurc),
            70,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            2e18,
            1500,
            TREASURY,
            2_000
        );
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduit.BelowFloor.selector, uint256(10), uint256(70)));
        bp2.executePermit2{value: 17e11}(pArc, TREASURY, hex"01", keccak256("bf"), bytes32(0), address(bVenue), lowFloor, fastQ);

        TreasuryBridgeConduit.Intent memory boom = _mkV3BridgeIntent(
            address(bVenue),
            abi.encodeCall(V3MockVenue.alwaysRevert, ()),
            ARC_NATIVE_USDC,
            100,
            address(eurc),
            70,
            TreasuryBridgeConduit.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            0,
            2000,
            TREASURY,
            2_000
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduit.TargetCallFailed.selector,
                abi.encodeWithSignature("Error(string)", "V3_VENUE_FAIL")
            )
        );
        bp2.executePermit2(pArc, TREASURY, hex"01", keccak256("boom"), bytes32(0), address(bVenue), boom, "");

        // Non-EVM recipient, UnexpectedBridgeTokenId, NativeFeeNotAllowed, QuoteNotAllowed, BridgeNotRegistered, ZeroMintRecipient
        TreasuryBridgeConduit.Intent memory badRecip = _mkV3BridgeIntent(
            address(0), "", address(eurc), 100, address(eurc), 100, TreasuryBridgeConduit.BridgeKind.CCTPX, address(ccts), EURC_ID, 1e15, 2000, TREASURY, 2_000
        );
        badRecip.mintRecipient = bytes32(uint256(1) << 160);
        TreasuryBridgeConduit.Authorization memory brAuth = _mkV3BridgeAuth(bp2, badRecip);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduit.NonEvmRecipient.selector, bytes32(uint256(1) << 160)));
        bp2.execute(brAuth, hex"01", badRecip, "");

        TreasuryBridgeConduit.Intent memory v2Bad = _mkV3BridgeIntent(
            address(0), "", address(eurc), 100, address(eurc), 100, TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), EURC_ID, 0, 2000, TREASURY, 2_000
        );
        TreasuryBridgeConduit.Authorization memory v2BadA = _mkV3BridgeAuth(bp2, v2Bad);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduit.UnexpectedBridgeTokenId.selector, EURC_ID));
        bp2.execute(v2BadA, hex"01", v2Bad, "");

        TreasuryBridgeConduit.Intent memory v2Ok = _mkV3BridgeIntent(
            address(0), "", address(eurc), 100, address(eurc), 100, TreasuryBridgeConduit.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        TreasuryBridgeConduit.Authorization memory v2OkA = _mkV3BridgeAuth(bp2, v2Ok);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduit.NativeFeeNotAllowed.selector, uint256(1)));
        bp2.execute{value: 1}(v2OkA, hex"01", v2Ok, "");

        vm.expectRevert(TreasuryBridgeConduit.QuoteNotAllowed.selector);
        bp2.execute(v2OkA, hex"01", v2Ok, hex"01");

        // Strict non-Arc 18-dec ERC-20 post-burn check on v3: even -1 drop with msg.value > 0 reverts
        V3TestToken tok18 = new V3TestToken(18);
        vm.prank(OWNER);
        bp2.setToken(address(tok18), true);
        tok18.mint(address(bp2), 1_000);
        tok18.mint(TREASURY, 500);
        TreasuryBridgeConduit.Intent memory i18 = _mkV3BridgeIntent(
            address(bVenue),
            abi.encodeCall(V3MockVenue.swap, (address(tok18), 100, address(eurc), 70, address(bp2))),
            address(tok18),
            100,
            address(eurc),
            70,
            TreasuryBridgeConduit.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            100,
            2000,
            TREASURY,
            2_000
        );
        TreasuryBridgeConduit.Authorization memory a18 = _mkV3BridgeAuth(bp2, i18);
        bytes memory q18 = _validCctpxQuote(5, 5, 2_000);
        ccts.setFaults(0, false, address(tok18), -1);
        vm.expectRevert(TreasuryBridgeConduit.PriorBalanceConsumed.selector);
        bp2.execute{value: 10}(a18, hex"01", i18, q18);

        ccts.setFaults(0, false, address(0), 0);
        bp2.execute{value: 10}(a18, hex"01", i18, q18);
    }

    function test_integration_v3TreasuryConduit_calls_TreasurySwapAndDeposit_withConduitBeneficiary() public {
        vm.warp(1_000);
        V3TestToken eurc = new V3TestToken(6);
        V3TestToken usdc = new V3TestToken(6);
        V3MockVenue venue = new V3MockVenue();
        V3MockShareVault4626 vault = new V3MockShareVault4626(usdc);

        TreasuryConduit conduit = new TreasuryConduit(OWNER);
        TreasurySwapAndDeposit sad = new TreasurySwapAndDeposit(OWNER, address(usdc));

        vm.startPrank(OWNER);
        conduit.setTarget(address(sad), true);
        conduit.setTarget(address(venue), true);
        conduit.setToken(address(eurc), true);
        sad.setVenue(address(venue), true);
        sad.setDest(address(vault), true);
        vm.stopPrank();

        eurc.mint(TREASURY, 1_000);

        bytes memory swapData = abi.encodeCall(V3MockVenue.swap, (address(eurc), 80, address(usdc), 95, address(sad)));
        bytes memory runData = abi.encodeCall(
            TreasurySwapAndDeposit.run,
            (
                address(eurc),
                100,
                address(venue),
                swapData,
                TreasurySwapAndDeposit.DestKind.Vault4626,
                address(vault),
                address(conduit),
                90
            )
        );
        TreasuryConduit.Intent memory intent =
            _mkConduitIntent(address(sad), runData, address(eurc), 100, address(vault), 95, TREASURY, 2_000);
        TreasuryConduit.Authorization memory auth = _mkConduitAuth(conduit, intent);

        conduit.execute(auth, hex"01", intent);

        assertEq(vault.balanceOf(TREASURY), 95, "treasury received 95 vault shares");
        assertEq(eurc.balanceOf(TREASURY), 920, "treasury received 20 unspent eurc refund");
        assertEq(usdc.balanceOf(address(vault)), 95, "vault holds 95 deposited usdc");
        assertEq(eurc.balanceOf(address(conduit)), 0, "zero eurc stranded on conduit");
        assertEq(usdc.balanceOf(address(conduit)), 0, "zero usdc stranded on conduit");
        assertEq(vault.balanceOf(address(conduit)), 0, "zero shares stranded on conduit");
        assertEq(eurc.balanceOf(address(sad)), 0, "zero eurc stranded on swapAndDeposit");
        assertEq(usdc.balanceOf(address(sad)), 0, "zero usdc stranded on swapAndDeposit");
        assertEq(vault.balanceOf(address(sad)), 0, "zero shares stranded on swapAndDeposit");
        assertEq(eurc.allowance(address(conduit), address(sad)), 0, "conduit allowance cleared");
        assertEq(eurc.allowance(address(sad), address(venue)), 0, "sad venue allowance cleared");
        assertEq(usdc.allowance(address(sad), address(vault)), 0, "sad vault allowance cleared");

        // Signing beneficiary = TREASURY bypasses conduit share measurement and reverts BelowFloor(0, 95)
        bytes memory directBeneficiaryRun = abi.encodeCall(
            TreasurySwapAndDeposit.run,
            (
                address(eurc),
                100,
                address(venue),
                swapData,
                TreasurySwapAndDeposit.DestKind.Vault4626,
                address(vault),
                TREASURY,
                90
            )
        );
        TreasuryConduit.Intent memory directBeneficiaryIntent =
            _mkConduitIntent(address(sad), directBeneficiaryRun, address(eurc), 100, address(vault), 95, TREASURY, 2_001);
        TreasuryConduit.Authorization memory directBeneficiaryAuth = _mkConduitAuth(conduit, directBeneficiaryIntent);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(95)));
        conduit.execute(directBeneficiaryAuth, hex"01", directBeneficiaryIntent);

        // Direct-to-treasury third-party share donation cannot satisfy minOut
        TreasuryConduit.Intent memory shareDonationIntent = _mkConduitIntent(
            address(venue),
            abi.encodeCall(V3MockVenue.deliverDirectSharesOnly, (vault, TREASURY, 500)),
            address(eurc),
            100,
            address(vault),
            95,
            TREASURY,
            2_002
        );
        TreasuryConduit.Authorization memory shareDonationAuth = _mkConduitAuth(conduit, shareDonationIntent);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(95)));
        conduit.execute(shareDonationAuth, hex"01", shareDonationIntent);
    }
}
