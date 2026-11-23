// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.24;

import {
    ICctpXFeeManager,
    ICrossChainTokenService,
    ITokenMessengerV2,
    TreasuryBridgeConduitV2
} from "../src/bufi/conduit/TreasuryBridgeConduitV2.sol";
import {TreasuryConduit} from "../src/bufi/conduit/TreasuryConduit.sol";
import {ITreasuryAddressBook, TreasuryConduitPermit2} from "../src/bufi/conduit/TreasuryConduitPermit2.sol";
import {TreasuryRedeemConduit} from "../src/bufi/conduit/TreasuryRedeemConduit.sol";
import {IPermit2SignatureTransfer} from "../src/bufi/conduit/interfaces/IPermit2SignatureTransfer.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function roll(uint256) external;
    function deal(address, uint256) external;
    function etch(address, bytes calldata) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool, address) external;
}

contract V2TestToken {
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    uint256 public feeBps;
    bool public skipDebitOnAuth;
    bool public skipDebitOnTransferFrom;
    uint256 public shrinkRecipientBy;
    uint256 public inflateRecipientBy;
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
        uint256 shrinkRecipientBy_,
        uint256 inflateRecipientBy_
    ) external {
        feeBps = feeBps_;
        skipDebitOnAuth = skipDebitOnAuth_;
        skipDebitOnTransferFrom = skipDebitOnTransferFrom_;
        shrinkRecipientBy = shrinkRecipientBy_;
        inflateRecipientBy = inflateRecipientBy_;
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
        balanceOf[to] += (amount - fee - transferShave) + inflateRecipientBy;
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

/// @notice Mirrors Arc's 6-decimal native-backed USDC precompile for one tracked conduit address.
contract V2MockArcNativeUsdc {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

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
            vm.deal(to, to.balance + amount * 1e12);
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

    function _move(address from, address to, uint256 amount) internal {
        if (from == trackedConduit) {
            uint256 weiDelta = amount * 1e12;
            require(from.balance >= weiDelta, "low native");
            vm.deal(from, from.balance - weiDelta);
        } else {
            _balances[from] -= amount;
        }
        if (to == trackedConduit) {
            vm.deal(to, to.balance + amount * 1e12);
        } else {
            _balances[to] += amount;
        }
    }
}

contract V2MockVenue {
    function swap(address tokenIn, uint256 spendIn, address tokenOut, uint256 deliverOut, address receiver) external {
        if (spendIn > 0) IERC20(tokenIn).transferFrom(msg.sender, address(this), spendIn);
        if (deliverOut > 0) V2TestToken(tokenOut).mint(receiver, deliverOut);
    }

    function swapSameToken(address token, uint256 spendIn, uint256 mintBack) external {
        if (spendIn > 0) IERC20(token).transferFrom(msg.sender, address(this), spendIn);
        if (mintBack > 0) V2TestToken(token).mint(msg.sender, mintBack);
    }

    function consumePrior(address token, uint256 extraTake) external {
        V2TestToken(token).forceTake(msg.sender, address(this), extraTake);
    }

    function deliverDirectInflowOnly(address tokenOut, address recipient, uint256 amount) external {
        V2TestToken(tokenOut).mint(recipient, amount);
    }

    function alwaysRevert() external pure {
        revert("VENUE_BOOM");
    }

    function reenterConduit(
        TreasuryConduit conduit,
        TreasuryConduit.Authorization calldata auth,
        bytes calldata sig,
        TreasuryConduit.Intent calldata intent
    ) external {
        conduit.execute(auth, sig, intent);
    }
}

contract V2MockPermit2 is IPermit2SignatureTransfer {
    bytes32 public lastWitness;
    address public lastOwner;
    address public lastTo;
    uint256 public lastRequestedAmount;
    uint256 public shortDeliverBy;
    bool public skipOwnerDebit;

    function setFaults(uint256 shortDeliverBy_, bool skipOwnerDebit_) external {
        shortDeliverBy = shortDeliverBy_;
        skipOwnerDebit = skipOwnerDebit_;
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return keccak256("MOCK_PERMIT2");
    }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata,
        bytes calldata
    ) external {
        lastWitness = witness;
        lastOwner = owner;
        lastTo = transferDetails.to;
        lastRequestedAmount = transferDetails.requestedAmount;
        uint256 amt = transferDetails.requestedAmount;
        if (!skipOwnerDebit) {
            V2TestToken(permit.permitted.token).forceTake(owner, address(this), amt);
        }
        uint256 deliver = amt - shortDeliverBy;
        if (deliver > 0) {
            V2TestToken(permit.permitted.token).mint(transferDetails.to, deliver);
        }
    }
}

contract V2MockAddressBook is ITreasuryAddressBook {
    mapping(address => address[]) internal _allowed;

    function setAllowed(address account, address[] calldata recipients) external {
        delete _allowed[account];
        for (uint256 i; i < recipients.length; ++i) {
            _allowed[account].push(recipients[i]);
        }
    }

    function getAllowedRecipients(address account) external view returns (address[] memory) {
        return _allowed[account];
    }
}

contract V2MockTokenMessengerV2 is ITokenMessengerV2 {
    uint256 public lastAmount;
    uint32 public lastDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastMinFinality;

    int256 public burnAdjust;
    address public stealToken;
    uint256 public stealAmount;

    function setFaults(int256 burnAdjust_, address stealToken_, uint256 stealAmount_) external {
        burnAdjust = burnAdjust_;
        stealToken = stealToken_;
        stealAmount = stealAmount_;
    }

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        lastAmount = amount;
        lastDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastMinFinality = minFinalityThreshold;

        if (burnAdjust > 0) {
            V2TestToken(burnToken).mint(msg.sender, uint256(burnAdjust));
        } else {
            uint256 pullAmt = burnAdjust < 0 ? amount - uint256(-burnAdjust) : amount;
            if (pullAmt > 0) IERC20(burnToken).transferFrom(msg.sender, address(0xdead), pullAmt);
        }
        if (stealToken != address(0) && stealAmount > 0) {
            V2TestToken(stealToken).forceTake(msg.sender, address(this), stealAmount);
        }
    }
}

contract V2MockFeeManager is ICctpXFeeManager {
    function decodeQuote(bytes calldata signedQuote) external pure returns (Quote memory) {
        require(signedQuote.length >= 2 && signedQuote[0] == 0x01, "bad quote");
        return abi.decode(signedQuote[1:], (Quote));
    }
}

contract V2MockTokenManager {
    function pullBurn(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(0xdead), amount);
    }
}

contract V2ForceEthFeeder {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

contract V2MockCcts is ICrossChainTokenService {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public override feeService;
    mapping(bytes32 => address) public managers;
    mapping(bytes32 => address) public tokenForId;
    int256 public burnAdjust;
    bool public leakNativeBackToConduit;
    address public extraMutateToken;
    int256 public extraMutateDelta;
    uint256 public lastMsgValue;
    bytes public lastDestAddr;

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
        bytes calldata destinationAddress,
        bytes32,
        uint32,
        QuoteClaim calldata,
        bool,
        bytes calldata
    ) external payable {
        lastMsgValue = msg.value;
        lastDestAddr = destinationAddress;
        address token = tokenForId[tokenId];
        address mgr = managers[tokenId];
        if (burnAdjust > 0) {
            V2TestToken(token).mint(msg.sender, uint256(burnAdjust));
        } else {
            uint256 pullAmt = burnAdjust < 0 ? amount - uint256(-burnAdjust) : amount;
            if (pullAmt > 0) V2MockTokenManager(mgr).pullBurn(token, msg.sender, pullAmt);
        }
        if (leakNativeBackToConduit) {
            new V2ForceEthFeeder{value: 1}(payable(msg.sender));
        }
        if (extraMutateToken != address(0) && extraMutateDelta != 0) {
            if (extraMutateDelta < 0) {
                V2TestToken(extraMutateToken).forceTake(msg.sender, address(this), uint256(-extraMutateDelta));
            } else {
                V2TestToken(extraMutateToken).mint(msg.sender, uint256(extraMutateDelta));
            }
        }
    }
}

contract V2MockTreasury1271 is IERC1271 {
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

contract V2MockVault4626 {
    V2TestToken public immutable assetToken;
    uint256 public deliverAssets;
    bool public tryReenter;
    TreasuryRedeemConduit public reenterTarget;

    constructor(V2TestToken assetToken_) {
        assetToken = assetToken_;
    }

    function setDeliver(uint256 deliverAssets_) external {
        deliverAssets = deliverAssets_;
    }

    function setReenter(bool enabled, TreasuryRedeemConduit target) external {
        tryReenter = enabled;
        reenterTarget = target;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        if (tryReenter) {
            tryReenter = false;
            reenterTarget.redeem(owner, address(this), shares, 1, block.timestamp + 100, 999, hex"01");
        }
        if (deliverAssets > 0) {
            assetToken.mint(receiver, deliverAssets);
        }
        return deliverAssets;
    }
}

contract TreasuryConduitsV2Test {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant OWNER = address(0xA11CE);
    address internal constant STRANGER = address(0xBAD);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant FEE_RECIPIENT = address(0xFEE1);
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ARC_NATIVE_USDC = 0x3600000000000000000000000000000000000000;
    bytes32 internal constant EURC_ID = keccak256("EURC");

    event TargetSet(address indexed target, bool allowed);
    event TokenSet(address indexed token, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event Executed(
        address indexed treasury,
        bytes32 indexed memoId,
        address indexed target,
        bytes32 nonce,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 gained,
        bytes memo
    );
    event Permit2RouteSet(address indexed target, address indexed allowanceTarget, bool allowed);
    event Permit2Executed(
        address indexed treasury,
        bytes32 indexed operationId,
        bytes32 indexed memoId,
        bytes32 documentCommitment,
        address target,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        address recipient,
        uint256 received,
        uint256 nonce,
        bytes32 intentHash,
        bytes memo
    );
    event BridgeSet(TreasuryBridgeConduitV2.BridgeKind indexed kind, address indexed bridge, bool allowed);
    event CctpxTokenSet(bytes32 indexed tokenId, address indexed token);
    event PlatformFeePaid(address indexed payer, address indexed token, address indexed recipient, uint256 amount);
    event Bridged(
        address indexed treasury,
        bytes32 indexed memoId,
        uint32 indexed destinationDomain,
        bytes32 nonce,
        TreasuryBridgeConduitV2.BridgeKind kind,
        address bridge,
        address tokenIn,
        uint256 amountIn,
        address bridgeAsset,
        uint256 burnAmount,
        bytes32 mintRecipient,
        uint256 maxFee,
        bytes memo
    );
    event VaultSet(address indexed vault, bool allowed);
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
        items[0] = ICctpXFeeManager.QuoteItem({quoteType: "FORWARD", quoteArgsHash: bytes32(0), amount: forwardFee});
        items[1] = ICctpXFeeManager.QuoteItem({quoteType: "PROTOCOL", quoteArgsHash: bytes32(0), amount: protocolFee});
        return _encodeQuote(
            ICctpXFeeManager.Quote({items: items, expiry: expiry, feeToken: address(0), nonce: 1, signature: hex"1234"})
        );
    }

    function _mkIntent(
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
            memoId: keccak256("memo-1"),
            memo: "hello"
        });
    }

    function _mkAuth(TreasuryConduit conduit, TreasuryConduit.Intent memory intent)
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
            nonce: conduit.intentNonce(intent)
        });
    }

    function _cloneAuth(TreasuryConduit.Authorization memory a)
        internal
        pure
        returns (TreasuryConduit.Authorization memory)
    {
        return TreasuryConduit.Authorization({
            token: a.token,
            from: a.from,
            value: a.value,
            validAfter: a.validAfter,
            validBefore: a.validBefore,
            nonce: a.nonce
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. TreasuryConduit (v2) — BugPoCer 5.1.9, 5.1.13, 5.2.1, 5.2.19 + mutations
    // ─────────────────────────────────────────────────────────────────────────

    function test_BugPoCer_5_2_1_v2ConduitTokenAllowlistAndExactPull() public {
        vm.warp(1_000);
        TreasuryConduit conduit = new TreasuryConduit(OWNER);
        V2TestToken tokenIn = new V2TestToken(6);
        V2TestToken tokenOut = new V2TestToken(6);
        V2MockVenue venue = new V2MockVenue();

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", STRANGER));
        conduit.setToken(address(tokenIn), true);

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        conduit.setToken(address(0), true);
        conduit.setTarget(address(venue), true);
        vm.stopPrank();

        tokenIn.mint(TREASURY, 1_000);
        TreasuryConduit.Intent memory intent = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 100, address(tokenOut), 95, address(conduit))),
            address(tokenIn),
            100,
            address(tokenOut),
            90,
            TREASURY,
            2_000
        );
        TreasuryConduit.Authorization memory auth = _mkAuth(conduit, intent);

        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.TokenNotRegistered.selector, address(tokenIn)));
        conduit.execute(auth, hex"01", intent);

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true, address(conduit));
        emit TokenSet(address(tokenIn), true);
        conduit.setToken(address(tokenIn), true);
        require(conduit.tokens(address(tokenIn)), "token registered");

        tokenIn.setConfig(100, false, false, 0, 0);
        vm.expectRevert(TreasuryConduit.InexactPull.selector);
        conduit.execute(auth, hex"01", intent);

        tokenIn.setConfig(0, true, false, 0, 0);
        vm.expectRevert(TreasuryConduit.InexactPull.selector);
        conduit.execute(auth, hex"01", intent);

        vm.prank(OWNER);
        conduit.setToken(address(tokenIn), false);
        tokenIn.setConfig(0, false, false, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.TokenNotRegistered.selector, address(tokenIn)));
        conduit.execute(auth, hex"01", intent);
    }

    function test_BugPoCer_5_1_9_v2ConduitDeltaOnlySweepPreservesStrayBalances() public {
        vm.warp(1_000);
        TreasuryConduit conduit = new TreasuryConduit(OWNER);
        V2TestToken tokenIn = new V2TestToken(6);
        V2TestToken tokenOut = new V2TestToken(6);
        V2MockVenue venue = new V2MockVenue();

        vm.startPrank(OWNER);
        conduit.setTarget(address(venue), true);
        conduit.setToken(address(tokenIn), true);
        vm.stopPrank();

        tokenIn.mint(address(conduit), 500);
        tokenOut.mint(address(conduit), 700);
        tokenIn.mint(TREASURY, 1_000);

        TreasuryConduit.Intent memory intent = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 70, address(tokenOut), 80, address(conduit))),
            address(tokenIn),
            100,
            address(tokenOut),
            80,
            TREASURY,
            1_000
        );
        TreasuryConduit.Authorization memory auth = _mkAuth(conduit, intent);

        vm.expectEmit(true, true, true, true, address(conduit));
        emit Executed(
            TREASURY, intent.memoId, address(venue), auth.nonce, address(tokenIn), 100, address(tokenOut), 80, "hello"
        );
        conduit.execute(auth, hex"01", intent);

        require(tokenIn.balanceOf(address(conduit)) == 500, "stray tokenIn preserved");
        require(tokenOut.balanceOf(address(conduit)) == 700, "stray tokenOut preserved");
        require(tokenIn.balanceOf(TREASURY) == 930, "treasury got 30 unspent refund");
        require(tokenOut.balanceOf(TREASURY) == 80, "treasury got 80 output");
        require(tokenIn.allowance(address(conduit), address(venue)) == 0, "allowance cleared");

        TreasuryConduit.Intent memory badIn = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.consumePrior, (address(tokenIn), 101)),
            address(tokenIn),
            100,
            address(tokenOut),
            0,
            TREASURY,
            2_000
        );
        TreasuryConduit.Authorization memory badInAuth = _mkAuth(conduit, badIn);
        vm.expectRevert(TreasuryConduit.PriorBalanceConsumed.selector);
        conduit.execute(badInAuth, hex"01", badIn);

        TreasuryConduit.Intent memory badOut = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.consumePrior, (address(tokenOut), 1)),
            address(tokenIn),
            100,
            address(tokenOut),
            0,
            TREASURY,
            2_000
        );
        TreasuryConduit.Authorization memory badOutAuth = _mkAuth(conduit, badOut);
        vm.expectRevert(TreasuryConduit.PriorBalanceConsumed.selector);
        conduit.execute(badOutAuth, hex"01", badOut);
    }

    function test_BugPoCer_5_1_13_v2ConduitRejectsThirdPartyInflowInflation() public {
        vm.warp(1_000);
        TreasuryConduit conduit = new TreasuryConduit(OWNER);
        V2TestToken tokenIn = new V2TestToken(6);
        V2TestToken tokenOut = new V2TestToken(6);
        V2MockVenue venue = new V2MockVenue();

        vm.startPrank(OWNER);
        conduit.setTarget(address(venue), true);
        conduit.setToken(address(tokenIn), true);
        vm.stopPrank();

        tokenIn.mint(TREASURY, 500);
        TreasuryConduit.Intent memory intent = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.deliverDirectInflowOnly, (address(tokenOut), TREASURY, 1_000)),
            address(tokenIn),
            100,
            address(tokenOut),
            100,
            TREASURY,
            2_000
        );
        TreasuryConduit.Authorization memory auth = _mkAuth(conduit, intent);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(100)));
        conduit.execute(auth, hex"01", intent);

        tokenOut.setConfig(1000, false, false, 0, 0);
        TreasuryConduit.Intent memory fotIntent = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 100, address(tokenOut), 100, address(conduit))),
            address(tokenIn),
            100,
            address(tokenOut),
            95,
            TREASURY,
            2_000
        );
        TreasuryConduit.Authorization memory fotAuth = _mkAuth(conduit, fotIntent);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(90), uint256(95)));
        conduit.execute(fotAuth, hex"01", fotIntent);

        tokenOut.mint(TREASURY, 50);
        tokenOut.setConfig(0, false, false, 10, 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(95)));
        conduit.execute(fotAuth, hex"01", fotIntent);
    }

    function test_BugPoCer_5_2_19_v2ConduitRescueEmitsEventAndGuards() public {
        TreasuryConduit conduit = new TreasuryConduit(OWNER);
        V2TestToken token = new V2TestToken(6);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", STRANGER));
        conduit.rescue(address(token), OWNER);

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        conduit.rescue(address(0), OWNER);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        conduit.rescue(address(token), address(0));
        vm.expectRevert(TreasuryConduit.NothingToSweep.selector);
        conduit.rescue(address(token), OWNER);

        token.mint(address(conduit), 420);
        vm.expectEmit(true, true, false, true, address(conduit));
        emit Rescued(address(token), TREASURY, 420);
        conduit.rescue(address(token), TREASURY);
        vm.stopPrank();

        require(token.balanceOf(TREASURY) == 420, "rescued");
        require(token.balanceOf(address(conduit)) == 0, "empty");
    }

    function test_v2Conduit_allValidationsSameTokenAndReentrancy() public {
        vm.warp(1_000);
        TreasuryConduit conduit = new TreasuryConduit(OWNER);
        V2TestToken tokenIn = new V2TestToken(6);
        V2TestToken tokenOut = new V2TestToken(6);
        V2MockVenue venue = new V2MockVenue();

        vm.startPrank(OWNER);
        conduit.setTarget(address(venue), true);
        conduit.setTarget(address(tokenIn), true);
        conduit.setTarget(address(tokenOut), true);
        conduit.setTarget(address(conduit), true);
        conduit.setToken(address(tokenIn), true);
        vm.stopPrank();

        tokenIn.mint(TREASURY, 2_000);
        bytes memory profitData = abi.encodeCall(V2MockVenue.swapSameToken, (address(tokenIn), 100, 125));
        TreasuryConduit.Intent memory base =
            _mkIntent(address(venue), profitData, address(tokenIn), 100, address(tokenIn), 25, TREASURY, 2_000);
        TreasuryConduit.Authorization memory auth = _mkAuth(conduit, base);

        TreasuryConduit.Authorization memory badAuth = _cloneAuth(auth);
        badAuth.from = address(0);
        vm.expectRevert(TreasuryConduit.InvalidTreasury.selector);
        conduit.execute(badAuth, hex"01", base);

        badAuth = _cloneAuth(auth);
        badAuth.from = address(conduit);
        vm.expectRevert(TreasuryConduit.InvalidTreasury.selector);
        conduit.execute(badAuth, hex"01", base);

        badAuth = _cloneAuth(auth);
        badAuth.from = STRANGER;
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BeneficiaryMismatch.selector, TREASURY, STRANGER));
        conduit.execute(badAuth, hex"01", base);

        badAuth = _cloneAuth(auth);
        badAuth.token = address(tokenOut);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryConduit.TokenMismatch.selector, address(tokenIn), address(tokenOut))
        );
        conduit.execute(badAuth, hex"01", base);

        badAuth = _cloneAuth(auth);
        badAuth.value = 99;
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.AmountMismatch.selector, uint256(100), uint256(99)));
        conduit.execute(badAuth, hex"01", base);

        TreasuryConduit.Intent memory zeroAmt =
            _mkIntent(address(venue), profitData, address(tokenIn), 0, address(tokenIn), 0, TREASURY, 2_000);
        TreasuryConduit.Authorization memory zeroAmtAuth = _mkAuth(conduit, zeroAmt);
        vm.expectRevert(TreasuryConduit.ZeroAmount.selector);
        conduit.execute(zeroAmtAuth, hex"01", zeroAmt);

        TreasuryConduit.Intent memory zeroOut =
            _mkIntent(address(venue), profitData, address(tokenIn), 100, address(0), 0, TREASURY, 2_000);
        TreasuryConduit.Authorization memory zeroOutAuth = _mkAuth(conduit, zeroOut);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        conduit.execute(zeroOutAuth, hex"01", zeroOut);

        badAuth = _cloneAuth(auth);
        badAuth.nonce = bytes32(uint256(1));
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryConduit.NonceIsNotTheIntent.selector, bytes32(uint256(1)), auth.nonce)
        );
        conduit.execute(badAuth, hex"01", base);

        vm.warp(2_001);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.IntentExpired.selector, uint256(2_000), uint256(2_001)));
        conduit.execute(auth, hex"01", base);
        vm.warp(1_000);

        TreasuryConduit.Intent memory unregTarget =
            _mkIntent(STRANGER, profitData, address(tokenIn), 100, address(tokenIn), 25, TREASURY, 2_000);
        TreasuryConduit.Authorization memory unregAuth = _mkAuth(conduit, unregTarget);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.TargetNotRegistered.selector, STRANGER));
        conduit.execute(unregAuth, hex"01", unregTarget);

        TreasuryConduit.Intent memory tIn =
            _mkIntent(address(tokenIn), profitData, address(tokenIn), 100, address(tokenIn), 25, TREASURY, 2_000);
        TreasuryConduit.Authorization memory tInAuth = _mkAuth(conduit, tIn);
        vm.expectRevert(TreasuryConduit.InvalidTarget.selector);
        conduit.execute(tInAuth, hex"01", tIn);

        TreasuryConduit.Intent memory tOut =
            _mkIntent(address(tokenOut), profitData, address(tokenIn), 100, address(tokenOut), 25, TREASURY, 2_000);
        TreasuryConduit.Authorization memory tOutAuth = _mkAuth(conduit, tOut);
        vm.expectRevert(TreasuryConduit.InvalidTarget.selector);
        conduit.execute(tOutAuth, hex"01", tOut);

        TreasuryConduit.Intent memory tSelf =
            _mkIntent(address(conduit), profitData, address(tokenIn), 100, address(tokenIn), 25, TREASURY, 2_000);
        TreasuryConduit.Authorization memory tSelfAuth = _mkAuth(conduit, tSelf);
        vm.expectRevert(TreasuryConduit.InvalidTarget.selector);
        conduit.execute(tSelfAuth, hex"01", tSelf);

        TreasuryConduit.Intent memory failIntent = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.alwaysRevert, ()),
            address(tokenIn),
            100,
            address(tokenIn),
            0,
            TREASURY,
            2_000
        );
        TreasuryConduit.Authorization memory failAuth = _mkAuth(conduit, failIntent);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryConduit.TargetCallFailed.selector, abi.encodeWithSignature("Error(string)", "VENUE_BOOM")
            )
        );
        conduit.execute(failAuth, hex"01", failIntent);

        tokenIn.mint(address(conduit), 300);
        conduit.execute(auth, hex"01", base);
        require(tokenIn.balanceOf(address(conduit)) == 300, "same-token stray preserved");
        require(tokenIn.balanceOf(TREASURY) == 2_025, "same-token profit");

        TreasuryConduit.Intent memory sameDeltaIntent =
            _mkIntent(address(venue), profitData, address(tokenIn), 100, address(tokenIn), 25, TREASURY, 1_999);
        TreasuryConduit.Authorization memory sameDeltaAuth = _mkAuth(conduit, sameDeltaIntent);
        tokenIn.setTransferShave(5);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(20), uint256(25)));
        conduit.execute(sameDeltaAuth, hex"01", sameDeltaIntent);
        tokenIn.setTransferShave(0);

        tokenIn.setConfig(0, false, false, 10, 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(25)));
        conduit.execute(sameDeltaAuth, hex"01", sameDeltaIntent);
        tokenIn.setConfig(0, false, false, 0, 0);

        TreasuryConduit.Intent memory zeroOutOk = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 100, address(tokenOut), 0, address(conduit))),
            address(tokenIn),
            100,
            address(tokenOut),
            0,
            TREASURY,
            2_000
        );
        conduit.execute(_mkAuth(conduit, zeroOutOk), hex"01", zeroOutOk);

        TreasuryConduit.Intent memory innerIntent = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 100, address(tokenOut), 50, address(conduit))),
            address(tokenIn),
            100,
            address(tokenOut),
            50,
            TREASURY,
            1_998
        );
        TreasuryConduit.Authorization memory innerAuth = _mkAuth(conduit, innerIntent);
        TreasuryConduit.Intent memory reenter = _mkIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.reenterConduit, (conduit, innerAuth, hex"01", innerIntent)),
            address(tokenIn),
            100,
            address(tokenOut),
            0,
            TREASURY,
            2_000
        );
        TreasuryConduit.Authorization memory reenterAuth = _mkAuth(conduit, reenter);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryConduit.TargetCallFailed.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            )
        );
        conduit.execute(reenterAuth, hex"01", reenter);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. TreasuryConduitPermit2 (v2) — BugPoCer 5.1.9, 5.1.13 + mutations
    // ─────────────────────────────────────────────────────────────────────────

    function _setupPermit2()
        internal
        returns (
            TreasuryConduitPermit2 p2,
            V2MockPermit2 mockP2,
            V2MockAddressBook book,
            V2TestToken tokenIn,
            V2TestToken tokenOut,
            V2MockVenue venue
        )
    {
        vm.warp(1_000);
        V2MockPermit2 impl = new V2MockPermit2();
        vm.etch(CANONICAL_PERMIT2, address(impl).code);
        mockP2 = V2MockPermit2(CANONICAL_PERMIT2);
        book = new V2MockAddressBook();
        tokenIn = new V2TestToken(6);
        tokenOut = new V2TestToken(6);
        venue = new V2MockVenue();
        vm.etch(TREASURY, hex"600080fd");
        p2 = new TreasuryConduitPermit2(OWNER, CANONICAL_PERMIT2, address(book));
    }

    function _mkP2Intent(
        address target,
        address allowanceTarget,
        bytes memory data,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        address recipient,
        uint256 deadline,
        bytes32 opId,
        bytes32 docCommit
    ) internal pure returns (TreasuryConduitPermit2.Permit2Intent memory) {
        return TreasuryConduitPermit2.Permit2Intent({
            operationId: opId,
            documentCommitment: docCommit,
            target: target,
            allowanceTarget: allowanceTarget,
            data: data,
            tokenIn: tokenIn,
            amountIn: amountIn,
            tokenOut: tokenOut,
            minOut: minOut,
            recipient: recipient,
            deadline: deadline,
            memoId: keccak256("p2-memo"),
            memo: "p2"
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

    function test_BugPoCer_5_1_9_and_5_1_13_v2Permit2Conduit() public {
        (
            TreasuryConduitPermit2 p2,
            ,
            V2MockAddressBook book,
            V2TestToken tokenIn,
            V2TestToken tokenOut,
            V2MockVenue venue
        ) = _setupPermit2();

        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true, address(p2));
        emit Permit2RouteSet(address(venue), address(venue), true);
        p2.setPermit2Route(address(venue), address(venue), true);

        tokenIn.mint(address(p2), 333);
        tokenOut.mint(address(p2), 444);
        tokenIn.mint(TREASURY, 1_000);

        IPermit2SignatureTransfer.PermitTransferFrom memory permit = _mkP2Permit(address(tokenIn), 100, 7, 1_000);

        TreasuryConduitPermit2.Permit2Intent memory inflowAttack = _mkP2Intent(
            address(venue),
            address(venue),
            abi.encodeCall(V2MockVenue.deliverDirectInflowOnly, (address(tokenOut), TREASURY, 500)),
            address(tokenIn),
            100,
            address(tokenOut),
            50,
            TREASURY,
            1_000,
            keccak256("op-inflow"),
            bytes32(0)
        );
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BelowFloor.selector, uint256(0), uint256(50)));
        p2.executePermit2(permit, TREASURY, hex"01", inflowAttack);

        address vendor = address(0x9999);
        address[] memory allowed = new address[](1);
        allowed[0] = vendor;
        book.setAllowed(TREASURY, allowed);

        TreasuryConduitPermit2.Permit2Intent memory okIntent = _mkP2Intent(
            address(venue),
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 75, address(tokenOut), 90, address(p2))),
            address(tokenIn),
            100,
            address(tokenOut),
            90,
            vendor,
            1_000,
            keccak256("op-ok"),
            keccak256("doc-1")
        );
        bytes32 expectedHash = p2.permit2IntentHash(TREASURY, okIntent);
        vm.expectEmit(true, true, true, true, address(p2));
        emit Permit2Executed(
            TREASURY,
            okIntent.operationId,
            okIntent.memoId,
            okIntent.documentCommitment,
            address(venue),
            address(tokenIn),
            100,
            address(tokenOut),
            vendor,
            90,
            7,
            expectedHash,
            "p2"
        );
        p2.executePermit2(permit, TREASURY, hex"01", okIntent);

        require(tokenIn.balanceOf(address(p2)) == 333, "stray in preserved");
        require(tokenOut.balanceOf(address(p2)) == 444, "stray out preserved");
        require(tokenIn.balanceOf(TREASURY) == 925, "refund 25 returned");
        require(tokenOut.balanceOf(vendor) == 90, "vendor got 90");
        require(p2.executed(TREASURY, okIntent.operationId), "marked executed");

        vm.expectRevert(TreasuryConduitPermit2.OperationAlreadyExecuted.selector);
        p2.executePermit2(permit, TREASURY, hex"01", okIntent);
    }

    function test_v2Permit2Conduit_allValidationAndFaultCases() public {
        (
            TreasuryConduitPermit2 p2,
            V2MockPermit2 mockP2,
            ,
            V2TestToken tokenIn,
            V2TestToken tokenOut,
            V2MockVenue venue
        ) = _setupPermit2();

        address bookAddr = address(p2.addressBook());
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Deployment.selector);
        new TreasuryConduitPermit2(OWNER, address(0x1234), bookAddr);
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Deployment.selector);
        new TreasuryConduitPermit2(OWNER, CANONICAL_PERMIT2, address(0x1234));

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", STRANGER));
        p2.setPermit2Route(address(venue), address(venue), true);

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.setPermit2Route(address(0xdead), address(venue), true);
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.setPermit2Route(address(venue), address(0xdead), true);
        p2.setPermit2Route(address(0xdead), address(0xdead), false);
        p2.setPermit2Route(address(venue), address(venue), true);
        p2.setPermit2Route(address(tokenIn), address(venue), true);
        p2.setPermit2Route(address(tokenOut), address(venue), true);
        p2.setPermit2Route(address(p2), address(venue), true);
        p2.setPermit2Route(CANONICAL_PERMIT2, address(venue), true);
        vm.stopPrank();

        tokenIn.mint(TREASURY, 5_000);
        tokenIn.mint(address(p2), 200);
        tokenOut.mint(address(p2), 200);

        bytes memory swapData = abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 100, address(tokenOut), 100, address(p2)));
        IPermit2SignatureTransfer.PermitTransferFrom memory permit = _mkP2Permit(address(tokenIn), 100, 1, 2_000);
        bytes32 opVal = keccak256("op-val");
        TreasuryConduitPermit2.Permit2Intent memory base = _mkP2Intent(
            address(venue), address(venue), swapData, address(tokenIn), 100, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0)
        );

        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(permit, address(p2), hex"01", base);
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(permit, STRANGER, hex"01", base);

        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 100, address(tokenOut), 100, TREASURY, 2_000, bytes32(0), bytes32(0))
        );
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 0, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0))
        );
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 100, address(tokenOut), 0, TREASURY, 2_000, opVal, bytes32(0))
        );
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 100, address(tokenOut), 100, address(0), 2_000, opVal, bytes32(0))
        );
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 100, address(tokenOut), 100, address(p2), 2_000, opVal, bytes32(0))
        );
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 100, address(tokenIn), 100, TREASURY, 2_000, opVal, bytes32(0))
        );
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, STRANGER, 100, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0))
        );
        vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 100, STRANGER, 100, TREASURY, 2_000, opVal, bytes32(0))
        );

        // Permit mismatches
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryConduit.TokenMismatch.selector, address(tokenIn), address(tokenOut))
        );
        p2.executePermit2(_mkP2Permit(address(tokenOut), 100, 1, 2_000), TREASURY, hex"01", base);

        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.AmountMismatch.selector, uint256(100), uint256(99)));
        p2.executePermit2(_mkP2Permit(address(tokenIn), 99, 1, 2_000), TREASURY, hex"01", base);

        vm.expectRevert(TreasuryConduitPermit2.Permit2DeadlineMismatch.selector);
        p2.executePermit2(_mkP2Permit(address(tokenIn), 100, 1, 1_999), TREASURY, hex"01", base);

        // Unregistered route
        vm.expectRevert(TreasuryConduitPermit2.Permit2RouteNotRegistered.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(tokenOut), swapData, address(tokenIn), 100, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0))
        );

        // Forbidden targets
        address[4] memory forbidden = [address(tokenIn), address(tokenOut), address(p2), CANONICAL_PERMIT2];
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(TreasuryConduitPermit2.InvalidPermit2Intent.selector);
            p2.executePermit2(
                permit,
                TREASURY,
                hex"01",
                _mkP2Intent(forbidden[i], address(venue), swapData, address(tokenIn), 100, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0))
            );
        }

        // BeneficiaryMismatch & RecipientNotInAddressBook
        vm.expectRevert(abi.encodeWithSelector(TreasuryConduit.BeneficiaryMismatch.selector, STRANGER, TREASURY));
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 100, address(tokenOut), 100, STRANGER, 2_000, opVal, bytes32(0))
        );

        vm.expectRevert(TreasuryConduitPermit2.RecipientNotInAddressBook.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), swapData, address(tokenIn), 100, address(tokenOut), 100, STRANGER, 2_000, opVal, keccak256("doc"))
        );

        // InexactInput on pull
        mockP2.setFaults(1, false);
        vm.expectRevert(TreasuryConduitPermit2.InexactInput.selector);
        p2.executePermit2(permit, TREASURY, hex"01", base);

        mockP2.setFaults(0, true);
        vm.expectRevert(TreasuryConduitPermit2.InexactInput.selector);
        p2.executePermit2(permit, TREASURY, hex"01", base);
        mockP2.setFaults(0, false);

        // AllowanceMismatch before & after
        tokenIn.setBadAllowance(false, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryConduitPermit2.AllowanceMismatch.selector,
                address(tokenIn),
                address(venue),
                uint256(100),
                uint256(99)
            )
        );
        p2.executePermit2(permit, TREASURY, hex"01", base);

        tokenIn.setBadAllowance(true, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryConduitPermit2.AllowanceMismatch.selector,
                address(tokenIn),
                address(venue),
                uint256(0),
                uint256(1)
            )
        );
        p2.executePermit2(permit, TREASURY, hex"01", base);
        tokenIn.setBadAllowance(false, false);

        // TargetCallFailed
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryConduit.TargetCallFailed.selector, abi.encodeWithSignature("Error(string)", "VENUE_BOOM")
            )
        );
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), abi.encodeCall(V2MockVenue.alwaysRevert, ()), address(tokenIn), 100, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0))
        );

        // PriorBalanceConsumed
        vm.expectRevert(TreasuryConduit.PriorBalanceConsumed.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), abi.encodeCall(V2MockVenue.consumePrior, (address(tokenIn), 101)), address(tokenIn), 100, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0))
        );

        vm.expectRevert(TreasuryConduit.PriorBalanceConsumed.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), abi.encodeCall(V2MockVenue.consumePrior, (address(tokenOut), 1)), address(tokenIn), 100, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0))
        );

        // Fee-on-transfer refund -> InexactInput
        tokenIn.setConfig(500, false, false, 0, 0);
        vm.expectRevert(TreasuryConduitPermit2.InexactInput.selector);
        p2.executePermit2(
            permit,
            TREASURY,
            hex"01",
            _mkP2Intent(address(venue), address(venue), abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 50, address(tokenOut), 100, address(p2))), address(tokenIn), 100, address(tokenOut), 100, TREASURY, 2_000, opVal, bytes32(0))
        );
        tokenIn.setConfig(0, false, false, 0, 0);

        // Fee-on-transfer output -> InexactOutput
        tokenOut.setConfig(500, false, false, 0, 0);
        vm.expectRevert(TreasuryConduitPermit2.InexactOutput.selector);
        p2.executePermit2(permit, TREASURY, hex"01", base);
        tokenOut.setConfig(0, false, false, 0, 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. TreasuryBridgeConduitV2 — BugPoCer 5.1.14, 5.2.1, 5.2.5, 5.2.18, 5.2.19
    // ─────────────────────────────────────────────────────────────────────────

    function _mkBridgeIntent(
        address venue,
        bytes memory venueData,
        address tokenIn,
        uint256 amountIn,
        address bridgeAsset,
        uint256 minBridgeAmount,
        TreasuryBridgeConduitV2.BridgeKind kind,
        address bridge,
        bytes32 bridgeTokenId,
        uint256 maxFee,
        uint32 minFinality,
        address beneficiary,
        uint256 deadline
    ) internal pure returns (TreasuryBridgeConduitV2.Intent memory) {
        return TreasuryBridgeConduitV2.Intent({
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
            memoId: keccak256("bridge-memo"),
            memo: "bridge",
            platformFeeToken: address(0),
            platformFeeAmount: 0,
            platformFeeRecipient: address(0)
        });
    }

    function _mkBridgeAuth(TreasuryBridgeConduitV2 b, TreasuryBridgeConduitV2.Intent memory intent)
        internal
        pure
        returns (TreasuryBridgeConduitV2.Authorization memory)
    {
        return TreasuryBridgeConduitV2.Authorization({
            token: intent.tokenIn,
            from: intent.beneficiary,
            value: intent.amountIn,
            validAfter: 0,
            validBefore: intent.deadline,
            nonce: b.intentNonce(intent)
        });
    }

    function _cloneBridgeAuth(TreasuryBridgeConduitV2.Authorization memory a)
        internal
        pure
        returns (TreasuryBridgeConduitV2.Authorization memory)
    {
        return TreasuryBridgeConduitV2.Authorization({
            token: a.token,
            from: a.from,
            value: a.value,
            validAfter: a.validAfter,
            validBefore: a.validBefore,
            nonce: a.nonce
        });
    }

    function test_BugPoCer_5_1_14_and_5_2_1_and_5_2_19_v2BridgeDeltaAndAllowlist() public {
        vm.warp(1_000);
        TreasuryBridgeConduitV2 b = new TreasuryBridgeConduitV2(OWNER);
        V2TestToken tokenIn = new V2TestToken(6);
        V2TestToken usdc = new V2TestToken(6);
        V2MockVenue venue = new V2MockVenue();
        V2MockTokenMessengerV2 messenger = new V2MockTokenMessengerV2();

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroAddress.selector);
        b.setToken(address(0), true);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroAddress.selector);
        b.setTarget(address(0), true);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroAddress.selector);
        b.setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(0), true);
        vm.expectRevert(TreasuryBridgeConduitV2.NativeAssetNotAllowed.selector);
        b.setCctpxToken(EURC_ID, ARC_NATIVE_USDC);

        b.setTarget(address(venue), true);
        b.setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), true);
        vm.stopPrank();

        tokenIn.mint(address(b), 400);
        usdc.mint(address(b), 600);
        tokenIn.mint(TREASURY, 1_000);

        TreasuryBridgeConduitV2.Intent memory intent = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 70, address(usdc), 85, address(b))),
            address(tokenIn),
            100,
            address(usdc),
            85,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            5,
            2000,
            TREASURY,
            1_000
        );
        intent.platformFeeToken = address(tokenIn);
        intent.platformFeeAmount = 10;
        intent.platformFeeRecipient = FEE_RECIPIENT;
        TreasuryBridgeConduitV2.Authorization memory auth = _mkBridgeAuth(b, intent);

        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.TokenNotRegistered.selector, address(tokenIn)));
        b.execute(auth, hex"01", intent, "");

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true, address(b));
        emit TokenSet(address(tokenIn), true);
        b.setToken(address(tokenIn), true);

        tokenIn.setConfig(100, false, false, 0, 0);
        vm.expectRevert(TreasuryBridgeConduitV2.InexactPull.selector);
        b.execute(auth, hex"01", intent, "");
        tokenIn.setConfig(0, true, false, 0, 0);
        vm.expectRevert(TreasuryBridgeConduitV2.InexactPull.selector);
        b.execute(auth, hex"01", intent, "");
        tokenIn.setConfig(0, false, false, 0, 0);

        vm.expectEmit(true, true, true, true, address(b));
        emit PlatformFeePaid(TREASURY, address(tokenIn), FEE_RECIPIENT, 10);
        vm.expectEmit(true, true, true, true, address(b));
        emit Bridged(
            TREASURY,
            intent.memoId,
            1,
            auth.nonce,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            address(tokenIn),
            100,
            address(usdc),
            85,
            intent.mintRecipient,
            5,
            "bridge"
        );
        b.execute(auth, hex"01", intent, "");

        require(tokenIn.balanceOf(address(b)) == 400, "stray tokenIn preserved");
        require(usdc.balanceOf(address(b)) == 600, "stray bridgeAsset preserved");
        require(tokenIn.balanceOf(FEE_RECIPIENT) == 10, "fee paid");
        require(tokenIn.balanceOf(TREASURY) == 920, "20 unspent input refunded");
        require(messenger.lastAmount() == 85, "burned exact delta");
        require(tokenIn.allowance(address(b), address(venue)) == 0, "venue allowance 0");
        require(usdc.allowance(address(b), address(messenger)) == 0, "bridge allowance 0");

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroAddress.selector);
        b.rescue(address(0), OWNER);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroAddress.selector);
        b.rescue(address(tokenIn), address(0));
        vm.expectEmit(true, true, false, true, address(b));
        emit Rescued(address(tokenIn), OWNER, 400);
        b.rescue(address(tokenIn), OWNER);
        vm.expectRevert(TreasuryBridgeConduitV2.NothingToSweep.selector);
        b.rescue(address(tokenIn), OWNER);
        vm.stopPrank();
        require(tokenIn.balanceOf(OWNER) == 400, "rescued");
    }

    function test_BugPoCer_5_2_5_and_5_2_18_v2BridgeArcNativeUsdcAndQuoteValidation() public {
        vm.warp(1_000);
        vm.roll(500);
        TreasuryBridgeConduitV2 b = new TreasuryBridgeConduitV2(OWNER);
        V2MockArcNativeUsdc impl = new V2MockArcNativeUsdc();
        vm.etch(ARC_NATIVE_USDC, address(impl).code);
        V2MockArcNativeUsdc arcUsdc = V2MockArcNativeUsdc(ARC_NATIVE_USDC);
        arcUsdc.setTrackedConduit(address(b));

        V2TestToken eurc = new V2TestToken(6);
        V2MockVenue venue = new V2MockVenue();
        V2MockFeeManager fm = new V2MockFeeManager();
        V2MockCcts ccts = new V2MockCcts(address(fm));
        V2MockTokenManager mgr = new V2MockTokenManager();
        ccts.setManager(EURC_ID, address(mgr), address(eurc));

        vm.startPrank(OWNER);
        b.setTarget(address(venue), true);
        b.setToken(ARC_NATIVE_USDC, true);
        b.setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTPX, address(ccts), true);
        vm.expectEmit(true, true, false, true, address(b));
        emit CctpxTokenSet(EURC_ID, address(eurc));
        b.setCctpxToken(EURC_ID, address(eurc));
        vm.stopPrank();

        vm.deal(address(b), 5 * 1e18 + 6e11);
        eurc.mint(address(b), 20);
        arcUsdc.mint(TREASURY, 1_000);
        vm.deal(address(this), 100 ether);

        TreasuryBridgeConduitV2.Intent memory intent = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (ARC_NATIVE_USDC, 70, address(eurc), 65, address(b))),
            ARC_NATIVE_USDC,
            100,
            address(eurc),
            65,
            TreasuryBridgeConduitV2.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            2e18,
            2000,
            TREASURY,
            2_000
        );
        TreasuryBridgeConduitV2.Authorization memory auth = _mkBridgeAuth(b, intent);

        // 5.2.18 quote validation checks (all quotes encoded BEFORE expectRevert!)
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, hex"01");

        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, hex"0200");

        ICctpXFeeManager.QuoteItem[] memory items = new ICctpXFeeManager.QuoteItem[](2);
        items[0] = ICctpXFeeManager.QuoteItem("FORWARD", bytes32(0), 5e11);
        items[1] = ICctpXFeeManager.QuoteItem("PROTOCOL", bytes32(0), 5e11);
        bytes memory q = _encodeQuote(ICctpXFeeManager.Quote(items, 2_000, address(eurc), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        q = _encodeQuote(ICctpXFeeManager.Quote(items, 2_000, address(0), 1, ""));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        ICctpXFeeManager.QuoteItem[] memory emptyItems = new ICctpXFeeManager.QuoteItem[](0);
        q = _encodeQuote(ICctpXFeeManager.Quote(emptyItems, 2_000, address(0), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        ICctpXFeeManager.QuoteItem[] memory fiveItems = new ICctpXFeeManager.QuoteItem[](5);
        for (uint256 i; i < 5; ++i) {
            fiveItems[i] = ICctpXFeeManager.QuoteItem("FORWARD", bytes32(0), 1);
        }
        q = _encodeQuote(ICctpXFeeManager.Quote(fiveItems, 2_000, address(0), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        items[1] = ICctpXFeeManager.QuoteItem("FORWARD", bytes32(0), 5e11);
        q = _encodeQuote(ICctpXFeeManager.Quote(items, 2_000, address(0), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        items[0] = ICctpXFeeManager.QuoteItem("PROTOCOL", bytes32(0), 5e11);
        items[1] = ICctpXFeeManager.QuoteItem("PROTOCOL", bytes32(0), 5e11);
        q = _encodeQuote(ICctpXFeeManager.Quote(items, 2_000, address(0), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        items[0] = ICctpXFeeManager.QuoteItem("MYSTERY", bytes32(0), 5e11);
        items[1] = ICctpXFeeManager.QuoteItem("PROTOCOL", bytes32(0), 5e11);
        q = _encodeQuote(ICctpXFeeManager.Quote(items, 2_000, address(0), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        items[0] = ICctpXFeeManager.QuoteItem("FORWARD", bytes32(0), 5e11);
        items[1] = ICctpXFeeManager.QuoteItem("PRE_FINALITY", bytes32(0), 5e11);
        q = _encodeQuote(ICctpXFeeManager.Quote(items, 2_000, address(0), 1, hex"aa"));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        q = _validCctpxQuote(5e11, 5e11, 999);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        q = _validCctpxQuote(5e11, 5e11, (uint256(1) << 248) | 499);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        q = _validCctpxQuote(5e11, 5e11, (uint256(2) << 248) | 9_999);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        q = _validCctpxQuote(10e11, 8e11, 2_000);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        q = _validCctpxQuote(2e18, 1e18, 2_000);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.FeeAboveMax.selector, uint256(3e18), uint256(2e18)));
        b.execute{value: 17e11}(auth, hex"01", intent, q);

        ccts.setFeeService(STRANGER);
        q = _validCctpxQuote(5e11, 5e11, 2_000);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);
        ccts.setFeeService(address(fm));

        ccts.setFaults(0, true, address(0), 0);
        vm.expectRevert(TreasuryBridgeConduitV2.NativeBalanceMismatch.selector);
        b.execute{value: 17e11}(auth, hex"01", intent, q);
        ccts.setFaults(0, false, address(0), 0);

        // Happy path: non-multiple of 1e12 (1.7e12) + dust (6e11) + partial swap refund!
        b.execute{value: 17e11}(auth, hex"01", intent, _validCctpxQuote(10e11, 7e11, 1_000));
        require(address(b).balance == 5 * 1e18 + 6e11, "exact stray native + dust preserved");
        require(eurc.balanceOf(address(b)) == 20, "stray eurc preserved");
        require(arcUsdc.balanceOf(TREASURY) == 930, "30 unspent Arc USDC refunded before burn");
        require(ccts.lastMsgValue() == 17e11, "native fee forwarded");

        // Fast finality (< 2000) with PRE_FINALITY + block.number expiry mode (mode == 1) + exact multiple of 1e12
        TreasuryBridgeConduitV2.Intent memory fastIntent = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (ARC_NATIVE_USDC, 70, address(eurc), 65, address(b))),
            ARC_NATIVE_USDC,
            100,
            address(eurc),
            65,
            TreasuryBridgeConduitV2.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            2e18,
            1999,
            TREASURY,
            2_000
        );
        TreasuryBridgeConduitV2.Authorization memory fastAuth = _mkBridgeAuth(b, fastIntent);
        uint256 validBlockExpiry = (uint256(1) << 248) | 500;

        ICctpXFeeManager.QuoteItem[] memory dupPre = new ICctpXFeeManager.QuoteItem[](2);
        dupPre[0] = ICctpXFeeManager.QuoteItem("PRE_FINALITY", bytes32(0), 1);
        dupPre[1] = ICctpXFeeManager.QuoteItem("PRE_FINALITY", bytes32(0), 1);
        q = _encodeQuote(ICctpXFeeManager.Quote(dupPre, validBlockExpiry, address(0), 2, hex"bb"));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidBridgeQuote.selector);
        b.execute{value: 2e18}(fastAuth, hex"01", fastIntent, q);

        ICctpXFeeManager.QuoteItem[] memory fastItems = new ICctpXFeeManager.QuoteItem[](3);
        fastItems[0] = ICctpXFeeManager.QuoteItem("FORWARD", bytes32(0), 1e18);
        fastItems[1] = ICctpXFeeManager.QuoteItem("PROTOCOL", bytes32(0), 5e17);
        fastItems[2] = ICctpXFeeManager.QuoteItem("PRE_FINALITY", bytes32(0), 5e17);
        q = _encodeQuote(ICctpXFeeManager.Quote(fastItems, validBlockExpiry, address(0), 2, hex"bb"));
        b.execute{value: 2e18}(fastAuth, hex"01", fastIntent, q);
        require(address(b).balance == 5 * 1e18 + 6e11, "stray still exact after fast burn");

        // Sub-unit native fee on Arc native USDC (nativeBefore / 1e12 == tokenInBefore, zero drop slack)
        TreasuryBridgeConduitV2.Intent memory subUnitIntent = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (ARC_NATIVE_USDC, 70, address(eurc), 65, address(b))),
            ARC_NATIVE_USDC,
            100,
            address(eurc),
            65,
            TreasuryBridgeConduitV2.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            2e18,
            2000,
            TREASURY,
            1_999
        );
        b.execute{value: 3e11}(_mkBridgeAuth(b, subUnitIntent), hex"01", subUnitIntent, _validCctpxQuote(2e11, 1e11, 2_000));
        require(address(b).balance == 5 * 1e18 + 6e11, "stray still exact after sub-unit Arc burn");

        // Any -1 drop OR +1 credit on a non-Arc ERC-20 tokenIn with msg.value > 0 reverts PriorBalanceConsumed
        V2TestToken tokenIn6 = new V2TestToken(6);
        vm.prank(OWNER);
        b.setToken(address(tokenIn6), true);
        tokenIn6.mint(address(b), 100);
        tokenIn6.mint(TREASURY, 500);
        TreasuryBridgeConduitV2.Intent memory nonNat = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn6), 100, address(eurc), 65, address(b))),
            address(tokenIn6),
            100,
            address(eurc),
            65,
            TreasuryBridgeConduitV2.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            2e18,
            2000,
            TREASURY,
            2_000
        );
        TreasuryBridgeConduitV2.Authorization memory nonNatAuth = _mkBridgeAuth(b, nonNat);
        q = _validCctpxQuote(5e11, 5e11, 2_000);
        ccts.setFaults(0, false, address(tokenIn6), -1);
        vm.expectRevert(TreasuryBridgeConduitV2.PriorBalanceConsumed.selector);
        b.execute{value: 1e12}(nonNatAuth, hex"01", nonNat, q);

        ccts.setFaults(0, false, address(tokenIn6), 1);
        vm.expectRevert(TreasuryBridgeConduitV2.PriorBalanceConsumed.selector);
        b.execute{value: 1e12}(nonNatAuth, hex"01", nonNat, q);
    }

    function test_v2Bridge_executePersonalAndAllValidationBranches() public {
        vm.warp(1_000);
        TreasuryBridgeConduitV2 b = new TreasuryBridgeConduitV2(OWNER);
        V2TestToken tokenIn = new V2TestToken(6);
        V2TestToken usdc = new V2TestToken(6);
        V2MockVenue venue = new V2MockVenue();
        V2MockTokenMessengerV2 messenger = new V2MockTokenMessengerV2();
        V2MockFeeManager fm = new V2MockFeeManager();
        V2MockCcts ccts = new V2MockCcts(address(fm));

        vm.startPrank(OWNER);
        b.setTarget(address(venue), true);
        b.setTarget(address(messenger), true);
        b.setTarget(address(tokenIn), true);
        b.setTarget(address(usdc), true);
        b.setTarget(address(b), true);
        b.setToken(address(usdc), true);
        b.setToken(address(tokenIn), true);
        b.setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), true);
        b.setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTPX, address(ccts), true);
        b.setCctpxToken(EURC_ID, address(usdc));
        vm.stopPrank();

        usdc.mint(address(b), 250);
        usdc.mint(TREASURY, 1_000);
        TreasuryBridgeConduitV2.Intent memory direct = _mkBridgeIntent(
            address(0),
            "",
            address(usdc),
            100,
            address(usdc),
            100,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            0,
            2000,
            TREASURY,
            2_000
        );

        vm.prank(STRANGER);
        vm.expectRevert(TreasuryBridgeConduitV2.PersonalCallerMismatch.selector);
        b.executePersonal(direct, "");

        vm.prank(address(b));
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidTreasury.selector);
        b.executePersonal(direct, "");

        TreasuryBridgeConduitV2.Intent memory badTok = _mkBridgeIntent(
            address(0),
            "",
            STRANGER,
            100,
            STRANGER,
            100,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            0,
            2000,
            TREASURY,
            2_000
        );
        vm.prank(TREASURY);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.TokenNotRegistered.selector, STRANGER));
        b.executePersonal(badTok, "");

        V2TestToken unregContractTok = new V2TestToken(6);
        unregContractTok.mint(TREASURY, 200);
        TreasuryBridgeConduitV2.Intent memory unregPersonal = _mkBridgeIntent(
            address(0),
            "",
            address(unregContractTok),
            100,
            address(unregContractTok),
            100,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            0,
            2000,
            TREASURY,
            2_000
        );
        vm.startPrank(TREASURY);
        unregContractTok.approve(address(b), 200);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryBridgeConduitV2.TokenNotRegistered.selector, address(unregContractTok))
        );
        b.executePersonal(unregPersonal, "");
        vm.stopPrank();

        vm.prank(OWNER);
        b.setToken(address(unregContractTok), true);
        vm.prank(TREASURY);
        b.executePersonal(unregPersonal, "");
        require(unregContractTok.balanceOf(TREASURY) == 100, "registered personal token succeeded");

        vm.startPrank(TREASURY);
        usdc.approve(address(b), 1_000);
        usdc.setConfig(500, false, false, 0, 0);
        vm.expectRevert(TreasuryBridgeConduitV2.InexactPull.selector);
        b.executePersonal(direct, "");
        usdc.setConfig(0, false, true, 0, 0);
        vm.expectRevert(TreasuryBridgeConduitV2.InexactPull.selector);
        b.executePersonal(direct, "");
        usdc.setConfig(0, false, false, 0, 0);

        b.executePersonal(direct, "");
        vm.stopPrank();
        require(usdc.balanceOf(address(b)) == 250, "personal direct stray preserved");
        require(usdc.balanceOf(TREASURY) == 900, "personal debited 100");

        // Authorization & intent checks
        TreasuryBridgeConduitV2.Authorization memory auth = _mkBridgeAuth(b, direct);
        TreasuryBridgeConduitV2.Authorization memory badAuth = _cloneBridgeAuth(auth);
        badAuth.nonce = bytes32(uint256(99));
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryBridgeConduitV2.NonceIsNotTheIntent.selector, bytes32(uint256(99)), auth.nonce)
        );
        b.execute(badAuth, hex"01", direct, "");

        badAuth = _cloneBridgeAuth(auth);
        badAuth.from = address(0);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidTreasury.selector);
        b.execute(badAuth, hex"01", direct, "");

        badAuth = _cloneBridgeAuth(auth);
        badAuth.from = address(b);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidTreasury.selector);
        b.execute(badAuth, hex"01", direct, "");

        badAuth = _cloneBridgeAuth(auth);
        badAuth.from = STRANGER;
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.BeneficiaryMismatch.selector, TREASURY, STRANGER));
        b.execute(badAuth, hex"01", direct, "");

        badAuth = _cloneBridgeAuth(auth);
        badAuth.token = address(tokenIn);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryBridgeConduitV2.TokenMismatch.selector, address(usdc), address(tokenIn))
        );
        b.execute(badAuth, hex"01", direct, "");

        badAuth = _cloneBridgeAuth(auth);
        badAuth.value = 99;
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.AmountMismatch.selector, uint256(100), uint256(99)));
        b.execute(badAuth, hex"01", direct, "");

        // ZeroBridgeFloor
        TreasuryBridgeConduitV2.Intent memory bad = _mkBridgeIntent(
            address(0), "", address(usdc), 100, address(usdc), 0, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        TreasuryBridgeConduitV2.Authorization memory a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroBridgeFloor.selector);
        b.execute(a, hex"01", bad, "");

        // Platform fee validation
        bad = _mkBridgeIntent(
            address(0), "", address(usdc), 100, address(usdc), 100, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        bad.platformFeeToken = address(usdc);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidPlatformFee.selector);
        b.execute(a, hex"01", bad, "");

        bad.platformFeeToken = address(0);
        bad.platformFeeRecipient = FEE_RECIPIENT;
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidPlatformFee.selector);
        b.execute(a, hex"01", bad, "");

        bad.platformFeeAmount = 100;
        bad.platformFeeToken = address(usdc);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidPlatformFee.selector);
        b.execute(a, hex"01", bad, "");

        bad.platformFeeAmount = 10;
        bad.platformFeeToken = address(tokenIn);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidPlatformFee.selector);
        b.execute(a, hex"01", bad, "");

        bad.platformFeeToken = address(usdc);
        bad.platformFeeRecipient = address(0);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidPlatformFee.selector);
        b.execute(a, hex"01", bad, "");

        bad.platformFeeRecipient = address(b);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidPlatformFee.selector);
        b.execute(a, hex"01", bad, "");

        bad.platformFeeRecipient = TREASURY;
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidPlatformFee.selector);
        b.execute(a, hex"01", bad, "");

        // ZeroAmount & Expired
        bad = _mkBridgeIntent(
            address(0), "", address(usdc), 0, address(usdc), 1, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroAmount.selector);
        b.execute(a, hex"01", bad, "");

        vm.warp(2_001);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryBridgeConduitV2.IntentExpired.selector, uint256(2_000), uint256(2_001))
        );
        b.execute(auth, hex"01", direct, "");
        vm.warp(1_000);

        // Venue errors
        bad = _mkBridgeIntent(
            address(0), hex"01", address(usdc), 100, address(usdc), 100, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.NoSwapButCalldata.selector);
        b.execute(a, hex"01", bad, "");

        bad = _mkBridgeIntent(
            address(0), "", address(tokenIn), 100, address(usdc), 100, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduitV2.NoSwapButTokensDiffer.selector, address(tokenIn), address(usdc)
            )
        );
        b.execute(a, hex"01", bad, "");

        bad.venue = STRANGER;
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.TargetNotRegistered.selector, STRANGER));
        b.execute(a, hex"01", bad, "");

        bad.venue = address(messenger);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.VenueIsABridge.selector, address(messenger)));
        b.execute(a, hex"01", bad, "");

        bad.venue = address(tokenIn);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidTarget.selector);
        b.execute(a, hex"01", bad, "");

        bad.venue = address(usdc);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidTarget.selector);
        b.execute(a, hex"01", bad, "");

        bad.venue = address(b);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.InvalidTarget.selector);
        b.execute(a, hex"01", bad, "");

        bad = _mkBridgeIntent(
            address(venue), "", address(usdc), 100, address(usdc), 100, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.SwapTokensIdentical.selector, address(usdc)));
        b.execute(a, hex"01", bad, "");

        // Bridge errors
        bad = _mkBridgeIntent(
            address(0), "", address(usdc), 100, address(usdc), 100, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, STRANGER, bytes32(0), 0, 2000, TREASURY, 2_000
        );
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduitV2.BridgeNotRegistered.selector,
                TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
                STRANGER
            )
        );
        b.execute(a, hex"01", bad, "");

        bad = _mkBridgeIntent(
            address(0), "", address(usdc), 100, address(usdc), 100, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        bad.mintRecipient = bytes32(0);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroMintRecipient.selector);
        b.execute(a, hex"01", bad, "");

        bad = _mkBridgeIntent(
            address(0), "", address(usdc), 100, address(usdc), 100, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), EURC_ID, 0, 2000, TREASURY, 2_000
        );
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.UnexpectedBridgeTokenId.selector, EURC_ID));
        b.execute(a, hex"01", bad, "");

        vm.deal(address(this), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.NativeFeeNotAllowed.selector, uint256(1)));
        b.execute{value: 1}(auth, hex"01", direct, "");

        vm.expectRevert(TreasuryBridgeConduitV2.QuoteNotAllowed.selector);
        b.execute(auth, hex"01", direct, hex"01");

        // CCTPX specific checks
        bad = _mkBridgeIntent(
            address(0), "", address(usdc), 100, address(usdc), 100, TreasuryBridgeConduitV2.BridgeKind.CCTPX, address(ccts), keccak256("UNKNOWN"), 10, 2000, TREASURY, 2_000
        );
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduitV2.BridgeTokenMismatch.selector, keccak256("UNKNOWN"), address(0), address(usdc)
            )
        );
        b.execute(a, hex"01", bad, "");

        bad.bridgeTokenId = EURC_ID;
        bad.mintRecipient = bytes32(uint256(1) << 160);
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryBridgeConduitV2.NonEvmRecipient.selector, bytes32(uint256(1) << 160))
        );
        b.execute(a, hex"01", bad, "");

        bad.mintRecipient = bytes32(uint256(uint160(address(0xBEEF))));
        a = _mkBridgeAuth(b, bad);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.FeeAboveMax.selector, uint256(11), uint256(10)));
        b.execute{value: 11}(a, hex"01", bad, "");

        bytes memory validQ = _validCctpxQuote(5, 5, 2_000);
        vm.expectRevert(TreasuryBridgeConduitV2.ZeroAddress.selector);
        b.execute{value: 10}(a, hex"01", bad, validQ);

        // BelowFloor, BurnMismatch, post-burn steal with msg.value == 0
        TreasuryBridgeConduitV2.Intent memory swapIntent = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 100, address(usdc), 50, address(b))),
            address(tokenIn),
            100,
            address(usdc),
            80,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            0,
            2000,
            TREASURY,
            2_000
        );
        tokenIn.mint(TREASURY, 1_000);
        a = _mkBridgeAuth(b, swapIntent);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.BelowFloor.selector, uint256(50), uint256(80)));
        b.execute(a, hex"01", swapIntent, "");

        swapIntent.minBridgeAmount = 50;
        a = _mkBridgeAuth(b, swapIntent);
        messenger.setFaults(-1, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.BurnMismatch.selector, uint256(49), uint256(50)));
        b.execute(a, hex"01", swapIntent, "");

        messenger.setFaults(5, address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.BurnMismatch.selector, uint256(0), uint256(50)));
        b.execute(a, hex"01", swapIntent, "");

        tokenIn.mint(address(b), 100);
        messenger.setFaults(0, address(tokenIn), 10);
        vm.expectRevert(TreasuryBridgeConduitV2.PriorBalanceConsumed.selector);
        b.execute(a, hex"01", swapIntent, "");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. TreasuryRedeemConduit (v2) — full unit & mutation-killing coverage
    // ─────────────────────────────────────────────────────────────────────────

    function test_v2RedeemConduit_fullCoverageAndMutationKilling() public {
        vm.warp(1_000);
        TreasuryRedeemConduit rc = new TreasuryRedeemConduit(OWNER);
        V2TestToken asset = new V2TestToken(6);
        V2MockTreasury1271 treasury = new V2MockTreasury1271();
        V2MockVault4626 vault = new V2MockVault4626(asset);

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", STRANGER));
        rc.setVault(address(vault), true);

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryRedeemConduit.ZeroAddress.selector);
        rc.setVault(address(0), true);
        vm.expectEmit(true, false, false, true, address(rc));
        emit VaultSet(address(vault), true);
        rc.setVault(address(vault), true);
        vm.stopPrank();

        bytes32 h0 = rc.redeemHash(address(treasury), address(vault), 100, 90, 1_000, 1);
        require(h0 != rc.redeemHash(STRANGER, address(vault), 100, 90, 1_000, 1), "treasury diff");
        require(h0 != rc.redeemHash(address(treasury), STRANGER, 100, 90, 1_000, 1), "vault diff");
        require(h0 != rc.redeemHash(address(treasury), address(vault), 101, 90, 1_000, 1), "shares diff");
        require(h0 != rc.redeemHash(address(treasury), address(vault), 100, 91, 1_000, 1), "minAssets diff");
        require(h0 != rc.redeemHash(address(treasury), address(vault), 100, 90, 1_001, 1), "deadline diff");
        require(h0 != rc.redeemHash(address(treasury), address(vault), 100, 90, 1_000, 2), "nonce diff");

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
        vault.setDeliver(89);
        vm.expectRevert(abi.encodeWithSelector(TreasuryRedeemConduit.BelowFloor.selector, uint256(89), uint256(90)));
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");
        require(!rc.usedNonces(address(treasury), 1), "revert keeps nonce unused");

        vault.setDeliver(90);
        treasury.setSecondDigest(rc.redeemHash(address(treasury), address(vault), 100, 1, block.timestamp + 100, 999));
        vault.setReenter(true, rc);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");
        treasury.setSecondDigest(bytes32(0));

        vault.setReenter(false, rc);
        vm.expectEmit(true, true, false, true, address(rc));
        emit Redeemed(address(treasury), address(vault), 100, 90, 1);
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");
        require(rc.usedNonces(address(treasury), 1), "nonce used");
        require(asset.balanceOf(address(treasury)) == 90, "assets delivered");

        vm.expectRevert(abi.encodeWithSelector(TreasuryRedeemConduit.NonceUsed.selector, uint256(1)));
        rc.redeem(address(treasury), address(vault), 100, 90, 1_000, 1, hex"01");

        vm.startPrank(OWNER);
        vm.expectRevert(TreasuryRedeemConduit.RenounceDisabled.selector);
        rc.renounceOwnership();
        rc.transferOwnership(STRANGER);
        vm.stopPrank();
        vm.prank(STRANGER);
        rc.acceptOwnership();
        require(rc.owner() == STRANGER, "two-step owner");
    }

    function test_v2Conduits_hashSensitivityGovernanceAndArgVerification() public {
        vm.warp(1_000);
        // 1. TreasuryConduit intentNonce sensitivity to all 10 fields + TargetSet/retire
        TreasuryConduit tc = new TreasuryConduit(OWNER);
        TreasuryConduit.Intent memory ti =
            _mkIntent(address(0x1), hex"aa", address(0x2), 100, address(0x3), 50, address(0x4), 2_000);
        bytes32 h = tc.intentNonce(ti);
        require(h != tc.intentNonce(_mkIntent(address(0x9), hex"aa", address(0x2), 100, address(0x3), 50, address(0x4), 2_000)), "target");
        require(h != tc.intentNonce(_mkIntent(address(0x1), hex"bb", address(0x2), 100, address(0x3), 50, address(0x4), 2_000)), "data");
        require(h != tc.intentNonce(_mkIntent(address(0x1), hex"aa", address(0x9), 100, address(0x3), 50, address(0x4), 2_000)), "tokenIn");
        require(h != tc.intentNonce(_mkIntent(address(0x1), hex"aa", address(0x2), 101, address(0x3), 50, address(0x4), 2_000)), "amountIn");
        require(h != tc.intentNonce(_mkIntent(address(0x1), hex"aa", address(0x2), 100, address(0x9), 50, address(0x4), 2_000)), "tokenOut");
        require(h != tc.intentNonce(_mkIntent(address(0x1), hex"aa", address(0x2), 100, address(0x3), 51, address(0x4), 2_000)), "minOut");
        require(h != tc.intentNonce(_mkIntent(address(0x1), hex"aa", address(0x2), 100, address(0x3), 50, address(0x9), 2_000)), "beneficiary");
        require(h != tc.intentNonce(_mkIntent(address(0x1), hex"aa", address(0x2), 100, address(0x3), 50, address(0x4), 2_001)), "deadline");
        ti.memoId = keccak256("other");
        require(h != tc.intentNonce(ti), "memoId");
        ti.memoId = keccak256("memo-1");
        ti.memo = "other";
        require(h != tc.intentNonce(ti), "memo");

        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true, address(tc));
        emit TargetSet(address(0x1), true);
        tc.setTarget(address(0x1), true);
        vm.prank(OWNER);
        tc.setTarget(address(0x1), false);
        require(!tc.targets(address(0x1)), "target retired");

        // 2. TreasuryConduitPermit2 intentHash sensitivity + multi-recipient addressBook + witness check
        (
            TreasuryConduitPermit2 p2,
            V2MockPermit2 mockP2,
            V2MockAddressBook book,
            V2TestToken tokenIn,
            V2TestToken tokenOut,
            V2MockVenue venue
        ) = _setupPermit2();
        TreasuryConduitPermit2.Permit2Intent memory pi = _mkP2Intent(
            address(venue), address(venue), hex"aa", address(tokenIn), 100, address(tokenOut), 50, TREASURY, 2_000, keccak256("op"), keccak256("doc")
        );
        bytes32 ph = p2.permit2IntentHash(TREASURY, pi);
        require(ph != p2.permit2IntentHash(STRANGER, pi), "p2 treasury");
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"aa", address(tokenIn), 100, address(tokenOut), 50, TREASURY, 2_000, keccak256("op2"), keccak256("doc"))),
            "p2 opId"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"aa", address(tokenIn), 100, address(tokenOut), 50, TREASURY, 2_000, keccak256("op"), keccak256("doc2"))),
            "p2 doc"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(STRANGER, address(venue), hex"aa", address(tokenIn), 100, address(tokenOut), 50, TREASURY, 2_000, keccak256("op"), keccak256("doc"))),
            "p2 target"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), STRANGER, hex"aa", address(tokenIn), 100, address(tokenOut), 50, TREASURY, 2_000, keccak256("op"), keccak256("doc"))),
            "p2 allowTarget"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"bb", address(tokenIn), 100, address(tokenOut), 50, TREASURY, 2_000, keccak256("op"), keccak256("doc"))),
            "p2 data"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"aa", STRANGER, 100, address(tokenOut), 50, TREASURY, 2_000, keccak256("op"), keccak256("doc"))),
            "p2 tokenIn"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"aa", address(tokenIn), 101, address(tokenOut), 50, TREASURY, 2_000, keccak256("op"), keccak256("doc"))),
            "p2 amountIn"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"aa", address(tokenIn), 100, STRANGER, 50, TREASURY, 2_000, keccak256("op"), keccak256("doc"))),
            "p2 tokenOut"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"aa", address(tokenIn), 100, address(tokenOut), 51, TREASURY, 2_000, keccak256("op"), keccak256("doc"))),
            "p2 minOut"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"aa", address(tokenIn), 100, address(tokenOut), 50, STRANGER, 2_000, keccak256("op"), keccak256("doc"))),
            "p2 recipient"
        );
        require(
            ph != p2.permit2IntentHash(TREASURY, _mkP2Intent(address(venue), address(venue), hex"aa", address(tokenIn), 100, address(tokenOut), 50, TREASURY, 2_001, keccak256("op"), keccak256("doc"))),
            "p2 deadline"
        );

        // Multi-recipient AddressBook check (match at index 1) + witness check
        address secondRecipient = address(0x8888);
        address[] memory list = new address[](2);
        list[0] = address(0x7777);
        list[1] = secondRecipient;
        book.setAllowed(TREASURY, list);
        vm.prank(OWNER);
        p2.setPermit2Route(address(venue), address(venue), true);
        tokenIn.mint(TREASURY, 200);
        TreasuryConduitPermit2.Permit2Intent memory multiIntent = _mkP2Intent(
            address(venue),
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 100, address(tokenOut), 50, address(p2))),
            address(tokenIn),
            100,
            address(tokenOut),
            50,
            secondRecipient,
            2_000,
            keccak256("op-idx1"),
            keccak256("doc-idx1")
        );
        bytes32 expectedWitness = keccak256(
            abi.encode(p2.CONDUIT_WITNESS_TYPEHASH(), multiIntent.operationId, p2.permit2IntentHash(TREASURY, multiIntent))
        );
        p2.executePermit2(_mkP2Permit(address(tokenIn), 100, 9, 2_000), TREASURY, hex"01", multiIntent);
        require(mockP2.lastWitness() == expectedWitness, "witness exact");
        require(mockP2.lastOwner() == TREASURY && mockP2.lastTo() == address(p2), "p2 pull args");

        // 3. TreasuryBridgeConduitV2 intentNonce sensitivity + depositForBurn / CCTPX arg checks + VenueIsABridge(CCTPX)
        TreasuryBridgeConduitV2 b = new TreasuryBridgeConduitV2(OWNER);
        V2MockTokenMessengerV2 messenger = new V2MockTokenMessengerV2();
        V2MockFeeManager fm = new V2MockFeeManager();
        V2MockCcts ccts = new V2MockCcts(address(fm));
        V2MockTokenManager mgr = new V2MockTokenManager();
        ccts.setManager(EURC_ID, address(mgr), address(tokenOut));

        vm.startPrank(OWNER);
        b.setTarget(address(venue), true);
        b.setTarget(address(ccts), true);
        b.setToken(address(tokenIn), true);
        b.setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), true);
        b.setBridge(TreasuryBridgeConduitV2.BridgeKind.CCTPX, address(ccts), true);
        b.setCctpxToken(EURC_ID, address(tokenOut));
        vm.stopPrank();

        TreasuryBridgeConduitV2.Intent memory bi = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tokenIn), 100, address(tokenOut), 80, address(b))),
            address(tokenIn),
            100,
            address(tokenOut),
            80,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            7,
            1000,
            TREASURY,
            2_000
        );
        bi.destinationCaller = bytes32(uint256(42));
        bytes32 bh = b.intentNonce(bi);
        bi.destinationDomain = 2;
        require(bh != b.intentNonce(bi), "domain");
        bi.destinationDomain = 1;
        bi.destinationCaller = bytes32(uint256(43));
        require(bh != b.intentNonce(bi), "caller");
        bi.destinationCaller = bytes32(uint256(42));
        bi.maxFee = 8;
        require(bh != b.intentNonce(bi), "maxFee");
        bi.maxFee = 7;
        bi.minFinalityThreshold = 2000;
        require(bh != b.intentNonce(bi), "finality");
        bi.minFinalityThreshold = 1000;
        bi.platformFeeAmount = 5;
        require(bh != b.intentNonce(bi), "pfAmt");
        bi.platformFeeAmount = 0;
        bi.platformFeeToken = address(tokenIn);
        require(bh != b.intentNonce(bi), "pfTok");
        bi.platformFeeToken = address(0);
        bi.platformFeeRecipient = FEE_RECIPIENT;
        require(bh != b.intentNonce(bi), "pfRecip");
        bi.platformFeeRecipient = address(0);
        bi.memo = "diff";
        require(bh != b.intentNonce(bi), "memo");
        bi.memo = "bridge";

        // Verify depositForBurn exact argument forwarding
        tokenIn.mint(TREASURY, 500);
        b.execute(_mkBridgeAuth(b, bi), hex"01", bi, "");
        require(messenger.lastAmount() == 80, "burn amt");
        require(messenger.lastDomain() == 1, "domain");
        require(messenger.lastMintRecipient() == bi.mintRecipient, "mintRecip");
        require(messenger.lastBurnToken() == address(tokenOut), "burnTok");
        require(messenger.lastDestinationCaller() == bytes32(uint256(42)), "destCaller");
        require(messenger.lastMaxFee() == 7, "maxFee");
        require(messenger.lastMinFinality() == 1000, "finality");

        // Verify VenueIsABridge for CCTPX + BridgeTokenMismatch when registered != bridgeAsset + PriorBalanceConsumed
        TreasuryBridgeConduitV2.Intent memory cctpxVenue = _mkBridgeIntent(
            address(ccts), "", address(tokenIn), 100, address(tokenOut), 80, TreasuryBridgeConduitV2.BridgeKind.CCTP_V2, address(messenger), bytes32(0), 0, 2000, TREASURY, 2_000
        );
        TreasuryBridgeConduitV2.Authorization memory cvAuth = _mkBridgeAuth(b, cctpxVenue);
        vm.expectRevert(abi.encodeWithSelector(TreasuryBridgeConduitV2.VenueIsABridge.selector, address(ccts)));
        b.execute(cvAuth, hex"01", cctpxVenue, "");

        TreasuryBridgeConduitV2.Intent memory wrongAsset = _mkBridgeIntent(
            address(0), "", address(tokenIn), 100, address(tokenIn), 80, TreasuryBridgeConduitV2.BridgeKind.CCTPX, address(ccts), EURC_ID, 0, 2000, TREASURY, 2_000
        );
        TreasuryBridgeConduitV2.Authorization memory waAuth = _mkBridgeAuth(b, wrongAsset);
        vm.expectRevert(
            abi.encodeWithSelector(
                TreasuryBridgeConduitV2.BridgeTokenMismatch.selector, EURC_ID, address(tokenOut), address(tokenIn)
            )
        );
        b.execute(waAuth, hex"01", wrongAsset, "");

        // Venue consumes prior tokenIn or bridgeAsset -> PriorBalanceConsumed
        tokenIn.mint(address(b), 50);
        tokenOut.mint(address(b), 50);
        TreasuryBridgeConduitV2.Intent memory stealIn = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.consumePrior, (address(tokenIn), 101)),
            address(tokenIn),
            100,
            address(tokenOut),
            1,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            0,
            2000,
            TREASURY,
            2_000
        );
        TreasuryBridgeConduitV2.Authorization memory siAuth = _mkBridgeAuth(b, stealIn);
        vm.expectRevert(TreasuryBridgeConduitV2.PriorBalanceConsumed.selector);
        b.execute(siAuth, hex"01", stealIn, "");

        TreasuryBridgeConduitV2.Intent memory stealOut = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.consumePrior, (address(tokenOut), 1)),
            address(tokenIn),
            100,
            address(tokenOut),
            1,
            TreasuryBridgeConduitV2.BridgeKind.CCTP_V2,
            address(messenger),
            bytes32(0),
            0,
            2000,
            TREASURY,
            2_000
        );
        TreasuryBridgeConduitV2.Authorization memory soAuth = _mkBridgeAuth(b, stealOut);
        vm.expectRevert(TreasuryBridgeConduitV2.PriorBalanceConsumed.selector);
        b.execute(soAuth, hex"01", stealOut, "");

        // CCTPX destinationAddress encoding check (20-byte packed address) + strict non-Arc ERC-20 post-burn check
        V2TestToken tok18 = new V2TestToken(18);
        vm.prank(OWNER);
        b.setToken(address(tok18), true);
        tok18.mint(address(b), 1_000);
        tok18.mint(TREASURY, 500);
        TreasuryBridgeConduitV2.Intent memory i18 = _mkBridgeIntent(
            address(venue),
            abi.encodeCall(V2MockVenue.swap, (address(tok18), 100, address(tokenOut), 80, address(b))),
            address(tok18),
            100,
            address(tokenOut),
            80,
            TreasuryBridgeConduitV2.BridgeKind.CCTPX,
            address(ccts),
            EURC_ID,
            100,
            2000,
            TREASURY,
            2_000
        );
        TreasuryBridgeConduitV2.Authorization memory a18 = _mkBridgeAuth(b, i18);
        vm.deal(address(this), 1 ether);
        bytes memory q18 = _validCctpxQuote(5, 5, 2_000);
        ccts.setFaults(0, false, address(tok18), -1);
        vm.expectRevert(TreasuryBridgeConduitV2.PriorBalanceConsumed.selector);
        b.execute{value: 10}(a18, hex"01", i18, q18);

        ccts.setFaults(0, false, address(0), 0);
        b.execute{value: 10}(a18, hex"01", i18, q18);
        require(
            keccak256(ccts.lastDestAddr()) == keccak256(abi.encodePacked(address(0xBEEF))), "cctpx 20-byte recipient"
        );
    }
}
